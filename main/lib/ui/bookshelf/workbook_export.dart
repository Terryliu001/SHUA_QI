import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/app/export/pdf_writer.dart';
import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/domain/export/export_options.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/answer_sheet.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/question_kind.dart';
import 'package:shuaqi/domain/model/session.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/infra/db/dao/page_dao.dart';
import 'package:shuaqi/infra/db/dao/question_dao.dart';
import 'package:shuaqi/infra/db/dao/session_dao.dart';
import 'package:shuaqi/infra/ink/answer_ink_store.dart';
import 'package:shuaqi/infra/ink/sif_ink_store.dart';
import 'package:shuaqi/infra/pdf/pdfrx_source.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';
import 'package:shuaqi/ui/reader/ink_painters.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';

/// 导出进度（UI 直接显示这几个字，不做花活）。
class ExportProgress {
  const ExportProgress(this.stage, {this.done = 0, this.total = 0});

  final String stage;
  final int done;
  final int total;

  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
}

/// 把一卷导出成 PDF（原题 / 笔迹 / 答题卡 任意组合）。
///
/// ## 为什么整页都走"栅格"
/// 笔迹层是矢量（SIF），但它铺在 PDF 页上；PDF 页只能由 pdfium 渲染成位图。
/// 想把两者合成又不引 PDF 编辑库，唯一稳的路是"合成 → 位图 → 嵌入"。
/// 代价是体积（一页 A4 在 1700px 宽下约 2–4MB）与不可选中文字；
/// 换来的是**所见即所得**：纸感之外的笔迹、跨页题、答题卡全部一致。
///
/// ## 会话口径
/// 笔迹按"这一卷最新的 draft 会话"取（与阅读器、答题卡一致）。
/// 交卷后新建的会话是二刷，不混进同一份导出——否则两份笔迹会叠在一起。
class WorkbookExporter {
  WorkbookExporter({
    required this.deps,
    required this.workbook,
    this.pageWidthPx = 0,
  });

  final AppDependencies deps;
  final Workbook workbook;

  /// 每页导出的像素宽。0 = 跟随 [ExportOptions.quality]（默认 2400px ≈ 290dpi）。
  ///
  /// 2026-10-26 用户第 14 条：1700px 打出来偏糊。默认提到 2400px，
  /// 仍可在导出面板里切回"标准"换小体积。
  final int pageWidthPx;

  PdfrxSource? _source;
  PageImageCache? _cache;

  Future<Uint8List> buildPdf(
    ExportOptions options, {
    void Function(ExportProgress progress)? onProgress,
  }) async {
    final List<WbPage> pages = await PageDao(deps.db.raw).pagesOf(workbook.id);
    if (pages.isEmpty) {
      throw StateError('这一卷还没有页数据');
    }
    final Session? session = await SessionDao(
      deps.db.raw,
    ).latestForWorkbook(workbook.id);
    final SifInkStore? ink = session == null || session.state != SessionState.draft
        ? null
        : SifInkStore(
            vault: deps.vault,
            db: deps.db.raw,
            workbookId: workbook.id,
          );

    final SimplePdfWriter writer = SimplePdfWriter(title: workbook.title);
    int step = 0;
    final int totalSteps =
        (options.original ? pages.length : 0) +
        (options.answer ? 1 : 0);

    try {
      if (options.original) {
        await _open();
        for (final WbPage page in pages) {
          onProgress?.call(
            ExportProgress('合成第 ${page.index + 1} 页', done: step, total: totalSteps),
          );
          final InkDoc doc = options.effectiveInk && ink != null && session != null
              ? await ink.load(session.id, page.index)
              : InkDoc.empty;
          final PdfImagePage? image = await _renderPage(
            page,
            doc,
            width: pageWidthPx > 0 ? pageWidthPx : options.quality.pageWidthPx,
          );
          if (image != null) {
            writer.addPage(image);
          }
          step += 1;
        }
      }

      if (options.answer) {
        onProgress?.call(
          ExportProgress('整理答题卡', done: step, total: totalSteps),
        );
        final List<AnswerPage> answered = await _collectAnswered(pages);
        step += 1;
        for (int i = 0; i < answered.length; i += 1) {
          onProgress?.call(
            ExportProgress(
              '答题卡 ${i + 1}/${answered.length}',
              done: step,
              total: totalSteps + answered.length,
            ),
          );
          final PdfImagePage? page = await _renderAnswerPage(answered[i]);
          if (page != null) {
            writer.addPage(page);
          }
        }
      }
    } finally {
      _cache?.dispose();
      _cache = null;
      await _source?.dispose();
      _source = null;
    }

    if (writer.isEmpty) {
      throw StateError('没有可导出的内容');
    }
    onProgress?.call(const ExportProgress('生成 PDF'));
    return writer.build();
  }

  Future<void> _open() async {
    if (_cache != null) {
      return;
    }
    final PdfrxSource source = await PdfrxSource.openFile(
      deps.vault.file(workbook.sourcePath).path,
    );
    _source = source;
    // 导出是"一次过"的批处理，缓存小一点更稳（一页 1700px 约 16MB）。
    _cache = PageImageCache(source: source, maxBytes: 96 * 1024 * 1024);
  }

  /// 合成一页：PDF 页 + 笔迹，输出 RGB 像素。
  Future<PdfImagePage?> _renderPage(
    WbPage page,
    InkDoc doc, {
    required int width,
  }) async {
    final PageImageCache? cache = _cache;
    if (cache == null || page.width <= 0 || page.height <= 0) {
      return null;
    }
    final int height = (width * page.height / page.width).round();
    if (height <= 0) {
      return null;
    }
    ui.Image? base;
    ui.Picture? picture;
    ui.Image? composed;
    try {
      base = await cache.obtain(page.index, width);
      final ui.Image? loaded = base;
      if (loaded == null) {
        return null;
      }
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      );
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = Colors.white,
      );
      canvas.scale(width / page.width);
      // PDF 页：整页铺满（`renderUiImage` 已按目标宽度等比出图）。
      canvas.drawImageRect(
        loaded,
        Rect.fromLTWH(
          0,
          0,
          loaded.width.toDouble(),
          loaded.height.toDouble(),
        ),
        Rect.fromLTWH(0, 0, page.width, page.height),
        Paint()..filterQuality = FilterQuality.medium,
      );
      if (doc.strokes.isNotEmpty) {
        final CommittedInkCache ink = CommittedInkCache()
          ..sync(doc, darkPaper: false, epoch: doc.revision);
        ink.draw(canvas);
      }
      picture = recorder.endRecording();
      composed = await picture.toImage(width, height);
      final ByteData? data = await composed.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) {
        return null;
      }
      return PdfImagePage(
        rgb: rgbFromRgba(data.buffer.asUint8List(), width, height),
        width: width,
        height: height,
        widthPt: page.width,
        heightPt: page.height,
      );
    } on Object {
      return null;
    } finally {
      composed?.dispose();
      picture?.dispose();
      base?.dispose();
    }
  }

  // ── 答题卡 ───────────────────────────────────────────────────────────

  /// 挑出"有作答"的题：有答题卡笔迹、有作答原图、或有识别文本。
  Future<List<AnswerPage>> _collectAnswered(List<WbPage> pages) async {
    final Session? session = await SessionDao(
      deps.db.raw,
    ).latestForWorkbook(workbook.id);
    if (session == null) {
      return const <AnswerPage>[];
    }
    final LayoutStore layout = LayoutStore(deps.vault);
    final AnswerSheetData sheet = AnswerSheetData.fromJson(
      await layout.readAnswerSheet(workbook.id),
    );
    final AnswerPaperData papers = AnswerPaperData.fromJson(
      await layout.readAnswerPaper(workbook.id),
    );
    final GradingData grading = GradingData.fromJson(
      await layout.readGrading(workbook.id),
    );
    final List<QuestionBundle> bundles = await QuestionDao(
      deps.db.raw,
    ).loadBundle(workbook.id);

    await _open();
    final List<AnswerPage> out = <AnswerPage>[];
    // 页内笔迹按页缓存：几十道题常常落在同一页，别为一页重读几十次 SIF。
    final Map<int, InkDoc> pageInkCache = <int, InkDoc>{};
    final SifInkStore pageInkStore = SifInkStore(
      vault: deps.vault,
      db: deps.db.raw,
      workbookId: workbook.id,
    );
    for (final QuestionBundle bundle in bundles) {
      if (bundle.slices.isEmpty) {
        continue;
      }
      final AnswerSheetEntry entry = sheet.regionFor(bundle);
      final int paperCount = papers.forQuestion(bundle.question.id).pages;
      final List<InkDoc> docs = <InkDoc>[];
      final AnswerInkStore store = AnswerInkStore(
        vault: deps.vault,
        workbookId: workbook.id,
        sessionId: session.id,
        questionId: bundle.question.id,
      );
      for (int i = 0; i < paperCount; i += 1) {
        final InkDoc doc = await store.load(session.id, i);
        if (doc.strokes.isNotEmpty) {
          docs.add(doc);
        }
      }
      final QuestionSlice slice = bundle.slices.first;
      // 用户在**卷面上直接写**的情况（本产品的主力用法）：答题卡里没有笔迹，
      // 但这一题的作答区域里有墨迹。那就把"页内这段作答"当成作答证据，
      // 否则「答题卡」这一段对绝大多数卷子都是空的。
      InkDoc? cachedInk = pageInkCache[slice.pageIndex];
      if (cachedInk == null) {
        cachedInk = await pageInkStore.load(session.id, slice.pageIndex);
        pageInkCache[slice.pageIndex] = cachedInk;
      }
      final InkDoc resolvedPageInk = cachedInk;
      bool regionTouched = false;
      for (final InkStroke stroke in resolvedPageInk.strokes) {
        final InkRect bounds = InkRect.fromPoints(stroke.points);
        final RegionRect strokeRect = RegionRect(
          left: bounds.left,
          top: bounds.top,
          width: bounds.width,
          height: bounds.height,
        );
        if (_overlaps(strokeRect, entry.rect)) {
          regionTouched = true;
          break;
        }
      }
      final bool hasOtherEvidence =
          entry.hasText || entry.hasCrop || entry.ocrAt > 0 || regionTouched;
      if (docs.isEmpty && !hasOtherEvidence) {
        continue;
      }
      final WbPage slicePage = pages.firstWhere(
        (WbPage p) => p.index == slice.pageIndex,
        orElse: () => pages.first,
      );
      out.add(
        AnswerPage(
          bundle: bundle,
          entry: entry,
          docs: docs,
          verdict: grading.verdictOf(bundle.question.id),
          pageSize: ui.Size(slicePage.width, slicePage.height),
          answerPaper: papers.forQuestion(bundle.question.id),
          pageInk: resolvedPageInk,
        ),
      );
    }
    return out;
  }

  /// 一页答题卡：题号 + 题图 + 作答纸（多张纵向排）。
  Future<PdfImagePage?> _renderAnswerPage(AnswerPage page) async {
    final PageImageCache? cache = _cache;
    if (cache == null) {
      return null;
    }
    const double widthPt = 595; // A4 宽（pt）
    const double marginPt = 36;
    const double titleHeightPt = 34;
    const double contentWidthPt = widthPt - marginPt * 2;
    // 题图高度按题面比例，最多占 38% 页高。
    final QuestionSlice slice = page.bundle.slices.first;
    final double rectRatio = slice.rect.width <= 0
        ? 0.3
        : slice.rect.height / slice.rect.width;
    final double questionHeightPt = (contentWidthPt * rectRatio).clamp(
      80.0,
      300.0,
    );
    // 有答题卡笔迹就按纸画；没有且页内有字 → 不画空纸（上面已画了作答区域）。
    final int paperCount = page.docs.isEmpty
        ? (page.pageInk.strokes.isEmpty ? 1 : 0)
        : page.docs.length;
    const double paperWidthPt = widthPt - marginPt * 2;
    // 纸张可能是纵向（A4 竖）也可能是横向：按**这道题自己的纸**算比例，
    // 不能用 `AnswerCanvas` 的默认 1000×600，否则竖纸会被压扁。
    final double paperAspect = page.answerPaper.widthPt <= 0
        ? AnswerCanvas.aspect
        : page.answerPaper.heightPt / page.answerPaper.widthPt;
    final double paperHeightPt = paperWidthPt * paperAspect;
    const double gapPt = 14;
    // 页内作答块（没有答题卡笔迹时才有）也要算进总高度，否则会被裁掉。
    final bool hasPageAnswer =
        page.docs.isEmpty && page.pageInk.strokes.isNotEmpty;
    final double pageAnswerHeight = hasPageAnswer
        ? (contentWidthPt *
                  (page.entry.rect.width <= 0
                      ? 0.3
                      : page.entry.rect.height / page.entry.rect.width))
              .clamp(80.0, 320.0)
        : 0;
    final double totalHeightPt =
        marginPt * 2 +
        titleHeightPt +
        questionHeightPt +
        gapPt +
        (hasPageAnswer ? pageAnswerHeight + gapPt : 0) +
        paperCount * paperHeightPt +
        (paperCount > 0 ? (paperCount - 1) * gapPt : 0);

    const int width = 1240;
    const double pxPerPt = width / widthPt;
    final int height = (totalHeightPt * pxPerPt).round();
    if (height <= 0 || height > 20000) {
      return null;
    }

    ui.Image? base;
    ui.Picture? picture;
    ui.Image? composed;
    try {
      base = await cache.obtain(slice.pageIndex, 1600);
      final ui.Image? pageImage = base;
      if (pageImage == null) {
        return null;
      }
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      );
      canvas.scale(pxPerPt);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, widthPt, totalHeightPt),
        Paint()..color = Colors.white,
      );

      // 标题：第 N 题 · 题型（右侧跟判定，便于快速扫）。
      double y = marginPt;
      _drawText(
        canvas,
        '第 ${questionLabelText(page.bundle.question.label ?? '')} 题'
        ' · ${questionKindLabel(page.bundle.question.kind)}',
        left: marginPt,
        top: y,
        fontSize: 15,
        bold: true,
      );
      final String verdictLabel = _verdictLabel(page.verdict);
      if (verdictLabel.isNotEmpty) {
        _drawText(
          canvas,
          '判定：$verdictLabel',
          left: widthPt - marginPt - 64,
          top: y + 2,
          fontSize: 10,
        );
      }
      y += titleHeightPt;

      // 题图：从 PDF 页裁出题面区域。
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(marginPt, y, contentWidthPt, questionHeightPt),
      );
      final double scale = contentWidthPt / slice.rect.width;
      canvas.translate(marginPt, y);
      canvas.scale(scale);
      canvas.translate(-slice.rect.left, -slice.rect.top);
      canvas.drawImageRect(
        pageImage,
        Rect.fromLTWH(
          0,
          0,
          pageImage.width.toDouble(),
          pageImage.height.toDouble(),
        ),
        Rect.fromLTWH(0, 0, page.pageSize.width, page.pageSize.height),
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
      y += questionHeightPt;
      _hairline(canvas, marginPt, y - gapPt / 2, contentWidthPt);
      y += gapPt;

      // 没有答题卡笔迹、但卷面上这一题有字：把"作答区域"整块（含墨迹）画出来。
      // 这才是页内书写用户真正想看到的"我的作答"。
      if (page.docs.isEmpty && page.pageInk.strokes.isNotEmpty) {
        // 高度按**作答框自己的比例**（不是题面比例）：作答区通常比题面矮。
        final double answerRatio = page.entry.rect.width <= 0
            ? 0.3
            : page.entry.rect.height / page.entry.rect.width;
        final double answerHeight = (contentWidthPt * answerRatio).clamp(
          80.0,
          320.0,
        );
        canvas.save();
        canvas.clipRect(
          Rect.fromLTWH(marginPt, y, contentWidthPt, answerHeight),
        );
        final double inkScale = contentWidthPt / page.entry.rect.width;
        canvas.translate(marginPt, y);
        canvas.scale(inkScale);
        canvas.translate(-page.entry.rect.left, -page.entry.rect.top);
        canvas.drawImageRect(
          pageImage,
          Rect.fromLTWH(
            0,
            0,
            pageImage.width.toDouble(),
            pageImage.height.toDouble(),
          ),
          Rect.fromLTWH(0, 0, page.pageSize.width, page.pageSize.height),
          Paint()..filterQuality = FilterQuality.medium,
        );
        final CommittedInkCache ink = CommittedInkCache()
          ..sync(page.pageInk, darkPaper: false, epoch: page.pageInk.revision);
        ink.draw(canvas);
        canvas.restore();
        y += answerHeight;
        _hairline(canvas, marginPt, y + gapPt / 2, contentWidthPt);
        y += gapPt;
      }

      // 作答纸：多张纵向排列。
      for (int i = 0; i < paperCount; i += 1) {
        canvas.drawRect(
          Rect.fromLTWH(marginPt, y, paperWidthPt, paperHeightPt),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.6
            ..color = const Color(0xFFD7D0C2),
        );
        if (i < page.docs.length) {
          canvas.save();
          canvas.translate(marginPt, y);
          canvas.scale(paperWidthPt / page.answerPaper.widthPt);
          final CommittedInkCache ink = CommittedInkCache()
            ..sync(page.docs[i], darkPaper: false, epoch: page.docs[i].revision);
          ink.draw(canvas);
          canvas.restore();
        }
        y += paperHeightPt;
        if (i < paperCount - 1) {
          y += gapPt;
        }
      }

      picture = recorder.endRecording();
      composed = await picture.toImage(width, height);
      final ByteData? data = await composed.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) {
        return null;
      }
      return PdfImagePage(
        rgb: rgbFromRgba(data.buffer.asUint8List(), width, height),
        width: width,
        height: height,
        widthPt: widthPt,
        heightPt: totalHeightPt,
      );
    } on Object {
      return null;
    } finally {
      composed?.dispose();
      picture?.dispose();
      base?.dispose();
    }
  }

  static String _verdictLabel(AnswerVerdict verdict) => switch (verdict) {
    AnswerVerdict.correct => '对',
    AnswerVerdict.wrong => '错',
    AnswerVerdict.pending => '待判',
    AnswerVerdict.none => '',
  };
}

/// 一页答题卡要用的素材。
class AnswerPage {
  const AnswerPage({
    required this.bundle,
    required this.entry,
    required this.docs,
    required this.verdict,
    required this.pageSize,
    required this.answerPaper,
    required this.pageInk,
  });

  final QuestionBundle bundle;
  final AnswerSheetEntry entry;
  final List<InkDoc> docs;
  final AnswerVerdict verdict;

  /// 题面所在页的 pt 尺寸（铺满页面时用）。
  final ui.Size pageSize;

  /// 这一题的答题纸尺寸/张数。笔迹坐标就是这套 pt，必须按它缩放。
  final AnswerPaper answerPaper;

  /// 题面所在页的整页笔迹（用户直接在卷面上写的情况）。
  final InkDoc pageInk;
}

/// 两个矩形是否相交（`RegionRect` 只有边与尺寸，没有现成的相交判定）。
bool _overlaps(RegionRect a, RegionRect b) =>
    a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;

void _hairline(Canvas canvas, double left, double top, double width) {
  canvas.drawLine(
    Offset(left, top),
    Offset(left + width, top),
    Paint()
      ..color = const Color(0xFFD7D0C2)
      ..strokeWidth = 0.6,
  );
}

/// 画一行文字（导出专用：不参与 widget 布局，直接画进 canvas）。
void _drawText(
  Canvas canvas,
  String text, {
  required double left,
  required double top,
  double fontSize = 12,
  bool bold = false,
}) {
  if (text.isEmpty) {
    return;
  }
  final TextPainter painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: const Color(0xFF1A1C1E),
        fontSize: fontSize,
        fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
        height: 1.2,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: 420);
  painter.paint(canvas, Offset(left, top));
  painter.dispose();
}

/// 把 PDF 交给系统（相册旁边的 `Download/SHUAQI`）。
///
/// 走与保存图片同一个 MethodChannel：Android 10+ 用 MediaStore 的 Downloads
/// 集合，不需要存储权限；低版本退回应用外部目录（系统文件管理器仍能看到）。
Future<String> savePdfToDownloads(Uint8List bytes, String fileName) async {
  const MethodChannel channel = MethodChannel('com.shuaqi.shuaqi/media');
  final String? path = await channel.invokeMethod<String>('savePdf', <String, Object?>{
    'bytes': bytes,
    'name': fileName,
  });
  return path ?? '';
}
