import 'package:shuaqi/app/region/l2_layout_cutter.dart';
import 'package:shuaqi/app/region/text_layer_extractor.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/region/confidence.dart';
import 'package:shuaqi/domain/region/correction.dart';
import 'package:shuaqi/domain/region/edited_question.dart';
import 'package:shuaqi/domain/region/id_keep.dart';
import 'package:shuaqi/domain/region/split.dart';
import 'package:shuaqi/domain/region/text_json.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:shuaqi/infra/db/app_database.dart';
import 'package:shuaqi/infra/db/dao/question_dao.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/infra/pdf/pdf_source.dart';
import 'package:shuaqi/infra/vault/corrections_store.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';
import 'package:sqflite/sqflite.dart';

/// 一次切题的结果。
class RegionBuildOutcome {
  const RegionBuildOutcome({
    required this.questions,
    required this.regions,
    required this.marks,
    required this.gradeCounts,
    required this.warnings,
    required this.elapsed,
    required this.textFromCache,
    this.cancelled = false,
    this.corrections = 0,
    this.edited = 0,
  });

  /// 题目数（含大题容器）。
  final int questions;

  /// 有区域的题目数。
  final int regions;

  /// 命中的题号数。
  final int marks;

  /// 三色分布，键是 `green` / `yellow` / `red`。
  final Map<String, int> gradeCounts;

  final List<String> warnings;
  final Duration elapsed;

  /// true 表示没重抽文本层，直接用了缓存。
  final bool textFromCache;
  final bool cancelled;

  /// 覆盖层里有多少条用户修改（0 = 纯自动结果）。
  final int corrections;

  /// 被用户改过的题数（含删除/合并/拆分/锁定）。
  final int edited;

  bool get isEmpty => regions == 0;
}

/// L1：抽文本层（必要时）→ 规则切题 → 写 `regions.v1.json` + 两张表（T3.1 + T3.2）。
///
/// 整个流程设计成**可重入、可取消、无副作用残留**：
/// - 文本层有缓存就直接用（切题是纯计算，几十毫秒，用户点"重新切题"可以随便点）；
/// - 写库放一个事务，失败整份回滚，不会留半份题目；
/// - 取消时**不写库**，但已抽到的文本层会落盘，下次接着用。
class RegionBuilder {
  const RegionBuilder({
    required this.source,
    required this.store,
    required this.corrections,
    required this.db,
  });

  final PdfSource source;
  final LayoutStore store;

  /// 用户覆盖层（T3.4）。自动结果永远只读，用户改的全在这一层。
  final CorrectionsStore corrections;
  final AppDatabase db;

  Future<RegionBuildOutcome> run(
    String workbookId, {
    required List<WbPage> pages,
    bool force = false,
    void Function(String stage)? onStage,
    bool Function()? isCancelled,
  }) async {
    final Stopwatch watch = Stopwatch()..start();

    onStage?.call('读取文本层');
    List<PageLines> pageLines = <PageLines>[];
    bool fromCache = false;
    if (!force) {
      final Map<String, Object?>? cached = await store.readText(workbookId);
      if (cached != null) {
        pageLines = decodeTextDocument(cached);
        fromCache = pageLines.length == pages.length && pageLines.isNotEmpty;
      }
    }

    if (!fromCache) {
      onStage?.call('抽取文本层');
      final TextExtractOutcome extracted = await TextLayerExtractor(
        source: source,
        store: store,
      ).run(workbookId, isCancelled: isCancelled);
      if (extracted.cancelled) {
        watch.stop();
        return RegionBuildOutcome(
          questions: 0,
          regions: 0,
          marks: 0,
          gradeCounts: const <String, int>{},
          warnings: const <String>['已取消'],
          elapsed: watch.elapsed,
          textFromCache: false,
          cancelled: true,
        );
      }
      final Map<String, Object?>? written = await store.readText(workbookId);
      pageLines = written == null
          ? const <PageLines>[]
          : decodeTextDocument(written);
    }

    onStage?.call('切题');
    SplitResult result = splitQuestions(pageLines);
    // 一个题号都没命中（扫描件，或文本层有但没题号）：走 L2。
    // 判据用 markCount 而不是 regionCount：markCount>0 说明题号规则已经认出了东西，
    // 只是层级把它判成了容器，这种情形不该被"切块"覆盖掉。
    if (result.markCount == 0) {
      // 先试行级（题号几何指纹 → 复用 L1 切分），能切出 ≥2 段就用它。
      onStage?.call('扫描件行分析');
      final SplitResult? scan = await L2LayoutCutter(
        source: source,
        cacheId: workbookId,
      ).runScan(pages, isCancelled: isCancelled);
      if (scan != null && scan.regionCount >= 2) {
        result = scan;
      } else {
        // 行级一条题号也没找到（整页图片、竖排、特殊编号）：退"内容块级"，
        // 至少给出可手改的粗框（034 的实现，保留）。
        onStage?.call('版面切块');
        final List<RegionDraft> blocks = await L2LayoutCutter(source: source)
            .run(pages, isCancelled: isCancelled);
        if (blocks.isNotEmpty) {
          result = layoutBlocksAsResult(blocks, pageCount: pages.length);
        }
      }
    }
    if (isCancelled?.call() ?? false) {
      watch.stop();
      return RegionBuildOutcome(
        questions: 0,
        regions: 0,
        marks: 0,
        gradeCounts: const <String, int>{},
        warnings: const <String>['已取消'],
        elapsed: watch.elapsed,
        textFromCache: fromCache,
        cancelled: true,
      );
    }

    // 自动结果落盘（**只读产物**）：用户编辑一律走 corrections.json，
    // 这样"重新切题"不会把用户辛苦修的框冲掉（规格 04 §T3.4 的硬要求）。
    await store.writeRegions(workbookId, <String, Object?>{
      ...result.toJson(kRegionDocumentVersion),
      // 记下"是哪一代算法切的"。打开卷子时发现代次落后会在后台静默重切
      // （2026-10-23：扫描件从块级升到题级，旧结果必须自动换掉，
      //  否则用户看到的还是 34 块装 44 道题的旧框）。
      'cutter': kCutterVersion,
    });

    onStage?.call('套用修改');
    final CorrectionLog log = await corrections.load(workbookId);
    final List<EditedQuestion> base = <EditedQuestion>[
      for (final RegionDraft draft in result.regions)
        EditedQuestion.fromDraft(draft),
    ];
    final List<EditedQuestion> effective = log.applyTo(base);
    final int editedCount = effective
        .where(
          (EditedQuestion q) =>
              q.deleted || q.locked || q.userAdded || _differs(q, base),
        )
        .length;

    onStage?.call('写入数据库');
    final Map<int, String> pageIdByIndex = <int, String>{
      for (final WbPage page in pages) page.index: page.id,
    };
    // 身份要**跨重算活下来**：先按 anchor（题号|页|y）把上一轮库里的 id 认领回来。
    // 否则每拖一次框，整卷 question.id 全换新 —— 第 5 周的"笔迹归属到题"、
    // 以及识别结果里的 question_id 会全部失联（见 domain/region/id_keep.dart）。
    final List<QuestionBundle> existing = await QuestionDao(db.raw)
        .loadBundle(workbookId);
    final List<String?> keptIds = matchExistingQuestionIds(
      oldIdByKey: <String, String>{
        for (final QuestionBundle bundle in existing)
          bundle.anchorKey: bundle.question.id,
      },
      newKeys: <String>[
        for (final EditedQuestion question in effective) question.key,
      ],
    );
    // 序号可能被拆分/新增改过（新题接在最后），所以先定一遍 ordinal → id。
    final Map<int, String> questionIdByOrdinal = <int, String>{};
    for (int i = 0; i < effective.length; i++) {
      questionIdByOrdinal[effective[i].ordinal] = keptIds[i] ?? Ulid.next();
    }
    final List<Question> questions = <Question>[];
    final List<QuestionRegion> regions = <QuestionRegion>[];
    final Map<String, int> gradeCounts = <String, int>{};
    for (final EditedQuestion question in effective) {
      // 软删除的题不落库（保留在覆盖层里，重切后还能按 anchor 找回来）。
      if (question.deleted) {
        continue;
      }
      final String id = questionIdByOrdinal[question.ordinal]!;
      questions.add(
        Question(
          id: id,
          workbookId: workbookId,
          ordinal: question.ordinal,
          level: question.level,
          confidence: question.confidence,
          label: question.label,
          parentId: question.parentOrdinal == null
              ? null
              : questionIdByOrdinal[question.parentOrdinal],
          kind: question.kind,
          stemText: question.stem.isEmpty ? null : question.stem,
          source: question.userAdded ? 'manual' : 'rule',
        ),
      );
      if (!question.hasRegion) {
        continue;
      }
      final String grade = RegionGrade.of(question.confidence).name;
      gradeCounts[grade] = (gradeCounts[grade] ?? 0) + 1;
      for (final PageSlice slice in question.slices) {
        final String? pageId = pageIdByIndex[slice.pageIndex];
        if (pageId == null) {
          continue;
        }
        regions.add(
          QuestionRegion(
            id: Ulid.next(),
            questionId: id,
            pageId: pageId,
            x: slice.rect.left,
            y: slice.rect.top,
            width: slice.rect.width,
            height: slice.rect.height,
            confidence: question.confidence,
            locked: question.locked,
          ),
        );
      }
    }

    // 有用户修改就是 manual：面板据此显示"已手改"，也提示"重新切题会保留这些修改"。
    final String status = effective.isEmpty
        ? LayoutStatus.text
        : (log.isEmpty ? LayoutStatus.auto : LayoutStatus.manual);
    await db.tx((Transaction txn) async {
      await QuestionDao(txn).replaceForWorkbook(
        workbookId: workbookId,
        questions: questions,
        regions: regions,
      );
      await WorkbookDao(txn).setLayoutStatus(workbookId, status);
    });
    // 答案与题目分开存：它是可重抽的自动结果，不参与覆盖层。
    // 即使这一卷没有答案也写空文件，重切时把旧答案清掉。
    await store.writeAnswers(workbookId, result.answers.toJson());

    watch.stop();
    return RegionBuildOutcome(
      questions: questions.length,
      regions: regions.isEmpty ? 0 : result.regionCount,
      marks: result.markCount,
      gradeCounts: gradeCounts,
      warnings: result.warnings,
      elapsed: watch.elapsed,
      textFromCache: fromCache,
      corrections: log.length,
      edited: editedCount,
    );
  }
}

/// 用户改过的题：几何变了、被删、被锁、或是手画的。
bool _differs(EditedQuestion question, List<EditedQuestion> base) {
  for (final EditedQuestion origin in base) {
    if (origin.key != question.key) {
      continue;
    }
    if (origin.locked == question.locked &&
        origin.deleted == question.deleted &&
        origin.slices.length == question.slices.length) {
      bool same = true;
      for (int i = 0; i < origin.slices.length; i++) {
        if (origin.slices[i].rect != question.slices[i].rect) {
          same = false;
          break;
        }
      }
      if (same) {
        return false;
      }
    }
    return true;
  }
  // 不在自动结果里（手画或拆分出来的下段）→ 算"改过"。
  return true;
}

/// `regions.v1.json` 的格式版本。
const int kRegionDocumentVersion = 1;

/// 切题算法代号。**只要切题逻辑变了就 +1**：打开卷子时发现库里是旧代号
/// 会在后台静默重切一次（用户不需要知道"重新切题"这个动作）。
///
/// - 1 = 只有 L1（文本层规则切题）+ 块级 L2；
/// - 2 = L2 升级成"行级 + 题号几何特征"（扫描件切到题，2026-10-23）；
/// - 3 = 题号识别改成**连通域字形分类**（数字/括号/中文序号分开判），并加了
///       行左边界去噪、分栏左边距取最左可信簇；真机两份扫描卷各 33 道题，
///       题数全对（2026-10-23 晚）。
/// - 4 = 题干按**行**保留换行（公式不再压成一行），配合显示层的数学字符归一化。
/// - 5 = 文末答案区抽取到 `answers.v1.json`（面板可对答案）；重切时保留覆盖层。
const int kCutterVersion = 5;
