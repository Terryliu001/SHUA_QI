import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/app/region/region_builder.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/region_set.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/region/answer.dart';
import 'package:shuaqi/domain/region/correction.dart';
import 'package:shuaqi/infra/db/dao/question_dao.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/infra/pdf/pdf_source.dart';
import 'package:shuaqi/infra/vault/corrections_store.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';
import 'package:shuaqi/state/app_providers.dart';

/// 题目区域相关的状态入口（第 3 周）。
///
/// 三条约定：
/// 1. **切题是无感的**：打开卷子时如果还没有区域，就在后台跑一次；界面不弹窗、
///    不遮挡、不 await（用户可以直接翻页写字）。
/// 2. **结果只有一份**：UI 一律从 [regionSetProvider] 读，切完 `invalidate` 它，
///    不要在页面里各存一份（否则开关面板/重切后两处不一致）。
/// 3. **切题可以被随时重跑**：切题是纯计算（几十毫秒）+ 一次事务写库，
///    "重新切题"不做任何确认弹窗。

final Provider<LayoutStore> layoutStoreProvider = Provider<LayoutStore>((
  Ref ref,
) {
  return LayoutStore(ref.watch(vaultProvider));
});

final Provider<CorrectionsStore> correctionsStoreProvider =
    Provider<CorrectionsStore>((Ref ref) {
      return CorrectionsStore(ref.watch(vaultProvider));
    });

final Provider<QuestionDao> questionDaoProvider = Provider<QuestionDao>((
  Ref ref,
) {
  return QuestionDao(ref.watch(appDependenciesProvider).db.raw);
});

/// 读库里的切题结果。切完调 `ref.invalidate(regionSetProvider(workbookId))`。
final FutureProvider<RegionSet> Function(String) regionSetProvider =
    FutureProvider.family<RegionSet, String>((
      Ref ref,
      String workbookId,
    ) async {
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      final List<QuestionBundle> bundles = await ref
          .watch(questionDaoProvider)
          .loadBundle(workbookId);
      final LayoutStore store = LayoutStore(deps.vault);
      final AnswerSet answers = AnswerSet.fromJson(
        await store.readAnswers(workbookId),
      ).mergeMissing(AnswerSet.fromJson(await store.readAiAnswers(workbookId)));
      return RegionSet(bundles, answers: answers);
    });

/// 切题的进度快照（给调试 HUD / "重新切题"的轻提示用；正常路径不显示任何东西）。
class RegionCutProgress {
  const RegionCutProgress({required this.stage, this.done, this.total});

  final String stage;
  final int? done;
  final int? total;
}

/// 切题执行器：负责"同一卷同时只跑一个"，并保证完成后刷新 [regionSetProvider]。
class RegionCutter {
  RegionCutter({
    required this.workbookId,
    required this.store,
    required this.corrections,
    required this.deps,
    required this.ref,
  });

  final String workbookId;
  final LayoutStore store;
  final CorrectionsStore corrections;
  final AppDependencies deps;
  final Ref ref;

  /// 最近一次进度。正常路径没有任何 UI 订阅它。
  final ValueNotifier<RegionCutProgress?> progress =
      ValueNotifier<RegionCutProgress?>(null);

  bool _running = false;

  bool get isRunning => _running;

  /// 需要时才切：已有区域且库里有题目、且**代次是最新的** → 什么都不做（返回 null）。
  ///
  /// [force] 为 true 表示用户点了"重新切题"：会重抽文本层并覆盖自动结果
  /// （用户的覆盖层 `corrections.json` 不在这里处理，T3.4 才引入）。
  Future<RegionBuildOutcome?> ensure({
    required PdfSource source,
    required List<WbPage> pages,
    bool force = false,
  }) async {
    if (_running) {
      return null;
    }
    if (!force) {
      final Workbook? workbook = await WorkbookDao(deps.db.raw)
          .byId(workbookId);
      final bool hasAuto =
          workbook?.layoutStatus == LayoutStatus.auto ||
          workbook?.layoutStatus == LayoutStatus.manual;
      if (hasAuto && store.hasRegionsSync(workbookId)) {
        final int existing = await QuestionDao(deps.db.raw).countOf(workbookId);
        if (existing > 0) {
          final Map<String, Object?>? doc = await store.readRegions(workbookId);
          // 算法换代了（比如扫描件从块级升到题级）：后台静默重切一次。
          // 覆盖层会按 anchor 重放，用户手改的框不会丢。
          if (doc?['cutter'] == kCutterVersion) {
            return null;
          }
        }
      }
    }
    return cut(source: source, pages: pages, force: force);
  }

  /// 无条件跑一次。
  Future<RegionBuildOutcome?> cut({
    required PdfSource source,
    required List<WbPage> pages,
    bool force = false,
  }) async {
    if (_running) {
      return null;
    }
    _running = true;
    progress.value = const RegionCutProgress(stage: '准备');
    try {
      final RegionBuildOutcome outcome =
          await RegionBuilder(
            source: source,
            store: store,
            corrections: corrections,
            db: deps.db,
          ).run(
            workbookId,
            pages: pages,
            force: force,
            onStage: (String stage) {
              progress.value = RegionCutProgress(stage: stage);
            },
          );
      if (!outcome.cancelled) {
        ref.invalidate(regionSetProvider(workbookId));
      }
      progress.value = null;
      return outcome;
    } finally {
      _running = false;
    }
  }

  void dispose() => progress.dispose();
}

final Provider<RegionCutter> Function(String) regionCutterProvider =
    Provider.family<RegionCutter, String>((Ref ref, String workbookId) {
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      final RegionCutter cutter = RegionCutter(
        workbookId: workbookId,
        store: ref.watch(layoutStoreProvider),
        corrections: ref.watch(correctionsStoreProvider),
        deps: deps,
        ref: ref,
      );
      ref.onDispose(cutter.dispose);
      return cutter;
    });

/// 区域编辑控制器（T3.4）：持有覆盖层、撤销/重做、以及"改完立刻重算"的编排。
///
/// ## 为什么每次编辑都整卷重算
/// 覆盖层是"操作列表"，改完不改库的话，UI 与库就会出现两份真相。
/// 重算走 `RegionBuilder`（文本层有缓存、切题 <1ms、一次事务写 30 行），
/// 实测整条链路在毫秒级——**功能优先，没必要为省这点时间造第二条增量写库的路径**。
///
/// ## 拖动为什么不在每帧重算
/// 拖的过程只在 widget 里画临时矩形；**抬手才落一条操作**（一次拖动 = 一步撤销）。
class RegionEditController {
  RegionEditController({
    required this.workbookId,
    required this.store,
    required this.cutter,
  });

  final String workbookId;
  final CorrectionsStore store;
  final RegionCutter cutter;

  /// 当前覆盖层。UI 用 `ValueListenableBuilder` 订阅，不走 Provider 重建整页。
  final ValueNotifier<CorrectionLog> log = ValueNotifier<CorrectionLog>(
    CorrectionLog.empty,
  );

  /// 重做栈（不落盘：进程重开后重做历史丢失是可以接受的，撤销历史不丢就行）。
  final List<RegionCorrection> _redo = <RegionCorrection>[];

  final ValueNotifier<int> redoDepth = ValueNotifier<int>(0);
  final ValueNotifier<bool> busy = ValueNotifier<bool>(false);

  bool _loaded = false;
  PdfSource? _source;
  List<WbPage> _pages = const <WbPage>[];
  bool _dirty = false;
  bool _recomputing = false;
  bool _pendingRecompute = false;

  bool get canUndo => log.value.ops.isNotEmpty;

  bool get canRedo => _redo.isNotEmpty;

  /// 打开卷子后调一次：载入覆盖层 + 记住切题用的上下文（后续编辑要重算）。
  Future<void> attach({
    required PdfSource source,
    required List<WbPage> pages,
  }) async {
    _source = source;
    _pages = pages;
    if (_loaded) {
      return;
    }
    _loaded = true;
    log.value = await store.load(workbookId);
  }

  /// 落一条编辑：**先落盘，再重算**。
  ///
  /// 顺序不能反：重算是从 `corrections.json` 读回覆盖层再套用的，
  /// 若走 300ms 防抖写盘，"第一次编辑"重算时文件还不存在 → 库与 UI 都不动
  /// （2026-10-23 真机踩到的真 bug：拖完框，文件里有 op，库里一点没变）。
  /// 一次编辑只写一份 ~1KB 的小文件，没必要为它做防抖。
  Future<void> run(RegionCorrection op) async {
    log.value = log.value.push(op);
    _redo.clear();
    redoDepth.value = 0;
    await _commit();
  }

  Future<void> undo() async {
    if (!canUndo) {
      return;
    }
    _redo.add(log.value.ops.last);
    log.value = log.value.dropLast();
    redoDepth.value = _redo.length;
    await _commit();
  }

  Future<void> redo() async {
    if (_redo.isEmpty) {
      return;
    }
    final RegionCorrection op = _redo.removeLast();
    redoDepth.value = _redo.length;
    log.value = log.value.push(op);
    await _commit();
  }

  /// 放弃全部修改（回到纯自动结果）。
  Future<void> clearAll() async {
    _redo.clear();
    redoDepth.value = 0;
    log.value = CorrectionLog.empty;
    _dirty = false;
    await store.clear(workbookId);
    await _recompute();
  }

  /// 落盘 + 重算（顺序不可交换，见 [run] 的说明）。
  Future<void> _commit() async {
    _dirty = false;
    await store.save(workbookId, log.value);
    await _recompute();
  }

  Future<void> _recompute() async {
    final PdfSource? source = _source;
    if (source == null) {
      return;
    }
    // 连续编辑（快速撤销/连续拖动）会撞上"同卷只跑一个"的锁：
    // 直接丢弃第二次重算会让库停在中间状态，所以这里合并——最后一次一定生效。
    if (_recomputing) {
      _pendingRecompute = true;
      return;
    }
    _recomputing = true;
    busy.value = true;
    try {
      do {
        _pendingRecompute = false;
        await cutter.cut(source: source, pages: _pages);
      } while (_pendingRecompute);
    } finally {
      _recomputing = false;
      busy.value = false;
    }
  }

  /// 立刻落盘（退出阅读器 / 生命周期回调里调）。
  ///
  /// 编辑路径已经"先落盘再重算"（见 [run]），所以这里主要是兜底：
  /// 极端情况下（比如 clearAll 之后进程被杀）也保证磁盘与内存一致。
  Future<void> flush() async {
    _dirty = false;
    await store.save(workbookId, log.value);
  }

  void dispose() {
    if (_dirty) {
      unawaited(store.save(workbookId, log.value));
    }
    log.dispose();
    redoDepth.dispose();
    busy.dispose();
  }
}

final Provider<RegionEditController> Function(String) regionEditProvider =
    Provider.family<RegionEditController, String>((Ref ref, String workbookId) {
      final RegionEditController controller = RegionEditController(
        workbookId: workbookId,
        store: ref.watch(correctionsStoreProvider),
        cutter: ref.watch(regionCutterProvider(workbookId)),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });
