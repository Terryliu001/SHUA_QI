import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_session_id.dart';
import 'package:shuaqi/domain/ink/ink_store.dart';
import 'package:shuaqi/domain/ink/undo_stack.dart';
import 'package:shuaqi/domain/records/answer_log.dart';
import 'package:shuaqi/domain/records/record_time.dart';
import 'package:shuaqi/infra/ink/answer_ink_store.dart';
import 'package:shuaqi/infra/ink/favorite_redo_ink_store.dart';
import 'package:shuaqi/infra/ink/ink_writer.dart';
import 'package:shuaqi/infra/ink/memory_ink_store.dart';
import 'package:shuaqi/infra/ink/sif_ink_store.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/record_providers.dart';
import 'package:shuaqi/state/redo_context.dart';

/// session id 的编解码在 `domain/ink/ink_session_id.dart`（数据契约，测试也要用）。
/// 这里 re-export，老的 `import state/ink_providers.dart` 不用改。
export 'package:shuaqi/domain/ink/ink_session_id.dart';

/// 笔迹存储（T2.4：真实 SIF 落盘）。
///
/// 按 **workbookId** 分 family：SIF 的路径是
/// `workbooks/<workbookId>/sessions/<sessionId>/ink/pNNN.sif`，
/// 而 [InkStore] 契约只有 session/page。store 实例记住 workbookId，
/// 契约本身保持规格里的签名不变。
///
/// `workbookId == ''` 时回落内存实现：编辑器的宿主机单测不建库、不碰文件。
final Provider<InkStore> Function(String) inkStoreProvider =
    Provider.family<InkStore, String>((Ref ref, String workbookId) {
      if (workbookId.isEmpty) {
        return MemoryInkStore();
      }
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      return SifInkStore(
        vault: deps.vault,
        db: deps.db.raw,
        workbookId: workbookId,
      );
    });

/// 落盘调度器（500ms 防抖）。阅读器生命周期里 `flushAll()`。
final Provider<InkWriter> Function(String) inkWriterProvider =
    Provider.family<InkWriter, String>((Ref ref, String workbookId) {
      final InkWriter writer = InkWriter(
        store: ref.watch(inkStoreProvider(workbookId)),
        // 测试（空 workbookId）走零防抖；生产 500ms。
        debounce: workbookId.isEmpty
            ? Duration.zero
            : const Duration(milliseconds: 500),
      );
      ref.onDispose(() {
        unawaited(writer.flushAll().whenComplete(writer.dispose));
      });
      return writer;
    });

/// 按页键选存储：普通 PDF 页走 SifInkStore；答题卡画布走 AnswerInkStore；
/// 收藏二刷走 FavoriteRedoInkStore。
final Provider<InkStore> Function(InkPageKey) inkStoreForKeyProvider =
    Provider.family<InkStore, InkPageKey>((Ref ref, InkPageKey key) {
      final ({String favoriteId, String? attemptId})? redo =
          parseFavoriteRedoSessionRef(key.sessionId);
      if (redo != null) {
        final AppDependencies redoDeps = ref.watch(appDependenciesProvider);
        return FavoriteRedoInkStore(
          vault: redoDeps.vault,
          favoriteId: redo.favoriteId,
          attemptId: redo.attemptId,
        );
      }
      final ({String sessionId, String questionId})? answer = parseAnswerInkSession(
        key.sessionId,
      );
      if (answer == null) {
        return ref.watch(inkStoreProvider(key.workbookId));
      }
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      return AnswerInkStore(
        vault: deps.vault,
        workbookId: key.workbookId,
        sessionId: answer.sessionId,
        questionId: answer.questionId,
      );
    });

/// 按页键选 writer：答题卡/二刷每题一个独立 writer，PDF 页共享阅读器 writer。
final Provider<InkWriter> Function(InkPageKey) inkWriterForKeyProvider =
    Provider.family<InkWriter, InkPageKey>((Ref ref, InkPageKey key) {
      final bool independent =
          parseFavoriteRedoSession(key.sessionId) != null ||
          parseAnswerInkSession(key.sessionId) != null;
      if (!independent) {
        return ref.watch(inkWriterProvider(key.workbookId));
      }
      final InkWriter writer = InkWriter(
        store: ref.watch(inkStoreForKeyProvider(key)),
        debounce: const Duration(milliseconds: 500),
      );
      ref.onDispose(() {
        unawaited(writer.flushAll().whenComplete(writer.dispose));
      });
      return writer;
    });

/// 一页笔迹的定位键。做成值对象而不是 `'$sessionId#$pageIndex'` 字符串：
/// family 的 arg 直接当 Map 键用，字符串拼接要小心分隔符碰撞，
/// 值对象靠结构相等，编译期就能发现漏字段。
class InkPageKey {
  const InkPageKey(this.sessionId, this.pageIndex, {this.workbookId = ''});

  final String sessionId;
  final int pageIndex;

  /// SIF 落盘路径需要它；宿主机单测不传（回落内存 store）。
  final String workbookId;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is InkPageKey &&
            other.sessionId == sessionId &&
            other.pageIndex == pageIndex &&
            other.workbookId == workbookId;
  }

  @override
  int get hashCode => Object.hash(sessionId, pageIndex, workbookId);

  @override
  String toString() => 'InkPageKey($workbookId/$sessionId#$pageIndex)';
}

/// 一页的编辑态：笔迹 + 撤销/重做是否可用。
///
/// 为什么把 canUndo/canRedo 和 doc 放在同一个 state：
/// 工具栏要按"这一页还有没有可撤销的"实时变色，若拆成两个 provider，
/// 每次抬笔/擦除都要两处通知，容易出现"按钮亮了但按下去没反应"。
class InkEditState {
  const InkEditState({
    required this.doc,
    this.canUndo = false,
    this.canRedo = false,
    this.epoch = 0,
    this.issue = InkLoadIssue.none,
  });

  final InkDoc doc;
  final bool canUndo;
  final bool canRedo;

  /// 落盘文件载入结果：备份恢复 / 损坏。UI 用它给一句明确提示。
  final InkLoadIssue issue;

  /// 结构性改动计数（2026-10-23 加，配合局部擦除）。
  ///
  /// 为什么要单独一个数：绘制层按"只追加"做增量缓存（抬笔只 append 一笔）。
  /// 但局部擦除会把**一笔换成两笔**（列表变长、前缀也变了），
  /// 只看 `strokeCount` 变没变会漏判（一笔变两笔时数量还可能刚好对得上）。
  /// epoch 只在"非追加"的改动（擦除 / 撤销 / 重做 / 清空 / 重新载入）时 +1，
  /// 绘制层看到 epoch 变了就整体重建一次，正确性用最便宜的方式保住。
  final int epoch;

  InkEditState copyWith({
    InkDoc? doc,
    bool? canUndo,
    bool? canRedo,
    int? epoch,
    InkLoadIssue? issue,
  }) {
    return InkEditState(
      doc: doc ?? this.doc,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
      epoch: epoch ?? this.epoch,
      issue: issue ?? this.issue,
    );
  }
}

/// 一页的笔迹状态（Notifier + family）。
///
/// 三条设计约束：
/// 1. **加载是异步的，但 UI 不能等**：`build()` 先返回空 doc（这一页还没读过就是空的，
///    合法初始态），加载完静默替换并清空撤销历史（历史对不上新基线）。
/// 2. **提交先改内存再落盘**：抬笔到上屏之间只有"点追加 + 通知"，落盘走异步（INV-01/INV-02）。
///    revision 以落盘返回为准回填——W4 的识别调度要拿它做版本校验。
/// 3. **所有改变笔画集合的操作都过 [UndoStack]**：抬笔、擦除、撤销、重做。
///    这样"撤销只动 stroke 列表、靠 revision 让识别失效"（INV-02）在实现层就是唯一的路径。
final NotifierProvider<InkEditController, InkEditState> Function(InkPageKey)
inkEditProvider =
    NotifierProvider.family<InkEditController, InkEditState, InkPageKey>(
      InkEditController.new,
    );

/// 只要笔迹本身的派生入口（绘制层用）。
///
/// 单独给一个 provider 是为了让"画布只关心笔画"这件事成立：
/// 撤销按钮变色不会把墨迹层重建一遍。
final Provider<InkDoc> Function(InkPageKey) inkDocProvider =
    Provider.family<InkDoc, InkPageKey>((Ref ref, InkPageKey key) {
      return ref.watch(inkEditProvider(key).select((InkEditState s) => s.doc));
    });

class InkEditController extends Notifier<InkEditState> {
  InkEditController(this._key);

  final InkPageKey _key;

  final UndoStack _history = UndoStack();

  /// 本次擦除拖动里累计的"替换"步骤（抬笔时合成**一步**撤销）。
  ///
  /// 局部擦除是"边划边切"，一次拖动可能对同一片区域切很多次；
  /// 每一步都记成一个 [EraseStrokes]，抬笔时包成 [EraseBatch] 压栈。
  /// 撤销时按相反顺序还原，能精确回到拖动之前的样子（不是"整笔恢复"）。
  final List<EraseStrokes> _pendingEraseSteps = <EraseStrokes>[];

  @override
  InkEditState build() {
    unawaited(_load());
    return const InkEditState(doc: InkDoc.empty);
  }

  InkDoc get doc => state.doc;

  Future<void> _load() async {
    final InkStore store = ref.read(inkStoreForKeyProvider(_key));
    InkDoc loaded = InkDoc.empty;
    InkLoadIssue issue = InkLoadIssue.none;
    try {
      loaded = await store.load(_key.sessionId, _key.pageIndex);
      if (store is InkIssueReporter) {
        issue = (store as InkIssueReporter).takeLoadIssue(
          _key.sessionId,
          _key.pageIndex,
        );
      }
    } on Object {
      // 载入异常不该把阅读器打崩；按空页处理，让用户继续写（原文件保留）。
      loaded = InkDoc.empty;
      issue = InkLoadIssue.corrupt;
    }
    if (!ref.mounted) {
      return;
    }
    // 竞态保护（T2.3 加固）：加载是异步的，用户可能在它返回之前就写了字。
    // 那时磁盘上那份旧内容**不能**覆盖内存——否则刚写的笔会凭空消失。
    // T2.4 换成真实文件 IO 后这个窗口会从"一个微任务"变成"十几毫秒"，必须挡。
    if (_history.canUndo || state.doc.strokeCount > 0) {
      return;
    }
    // 磁盘来的 doc 是新的基线：旧历史（如果有）对不上，直接清掉。
    _history.clear();
    _pendingEraseSteps.clear();
    state = InkEditState(doc: loaded, epoch: state.epoch + 1, issue: issue);
  }

  // ── 书写 ─────────────────────────────────────────────────────────

  /// 抬笔提交一笔。返回新 revision（内存版本）。
  ///
  /// **只追加**：不动 epoch，绘制层可以走"只 append 一笔"的增量路径。
  Future<int> commit(InkStroke stroke) async {
    _applyCommand(AddStroke(stroke), structural: false);
    return state.doc.revision;
  }

  // ── 擦除（T2.3 / 2026-10-23 改为局部擦除）───────────────────────

  /// 应用一批"笔画 → 碎片"的替换（局部擦除的一步）。
  ///
  /// 立即改 doc（用户要马上看到被擦掉的那一段消失），但**先不进撤销栈**——
  /// 抬笔时整次拖动合成一步撤销。
  void applyErasePatches(List<ErasePatch> patches) {
    if (patches.isEmpty) {
      return;
    }
    final EraseStrokes step = EraseStrokes(patches);
    final InkDoc next = step.apply(state.doc);
    _pendingEraseSteps.add(step);
    state = state.copyWith(
      doc: next,
      canRedo: false,
      // 结构变了（一笔可能变两笔），绘制层必须整体重建。
      epoch: state.epoch + 1,
    );
  }

  /// 擦除结束（抬笔）：把整次拖动合成一条命令进撤销栈。
  void endErase() {
    if (_pendingEraseSteps.isEmpty) {
      return;
    }
    final EraseBatch batch = EraseBatch(
      List<EraseStrokes>.of(_pendingEraseSteps),
    );
    _pendingEraseSteps.clear();
    _history.push(batch);
    state = state.copyWith(
      canUndo: _history.canUndo,
      canRedo: _history.canRedo,
    );
    _scheduleSave();
  }

  /// 第二根手指落下 = 双指手势：**撤回**本次擦除，不留撤销项。
  ///
  /// 和 [cancelErase] 的区别：cancel 是"擦到一半但确实想擦"，收尾成一步撤销；
  /// abort 是"误触/想缩放"，必须把 doc 还原到擦除前，否则用户会莫名少半页。
  void abortErase() {
    if (_pendingEraseSteps.isEmpty) {
      return;
    }
    InkDoc next = state.doc;
    for (final EraseStrokes step in _pendingEraseSteps.reversed) {
      next = step.revert(next);
    }
    _pendingEraseSteps.clear();
    state = state.copyWith(
      doc: next,
      canUndo: _history.canUndo,
      canRedo: false,
      epoch: state.epoch + 1,
    );
    _scheduleSave();
  }

  /// 放弃进行中的擦除（笔被 cancel / 页面被换掉）：已擦的仍然算数，
  /// 但同样要收尾成一步撤销，否则用户"按了撤销却跳到更早的状态"。
  void cancelErase() => endErase();

  // ── 撤销 / 重做（T2.3）───────────────────────────────────────────

  /// 撤销一步。没有可撤销的返回 false（UI 据此不再弹提示）。
  bool undo() {
    // 擦除划到一半就按了撤销：先把这次拖动收尾成一步，
    // 否则那几笔被擦了却不在历史里，用户"撤销恢复不了"（真失数据）。
    _settlePendingErase();
    final InkCommand? command = _history.takeUndo();
    if (command == null) {
      return false;
    }
    state = state.copyWith(
      doc: command.revert(state.doc),
      canUndo: _history.canUndo,
      canRedo: _history.canRedo,
      epoch: state.epoch + 1,
    );
    _scheduleSave();
    return true;
  }

  /// 重做一步。
  bool redo() {
    _settlePendingErase();
    final InkCommand? command = _history.takeRedo();
    if (command == null) {
      return false;
    }
    state = state.copyWith(
      doc: command.apply(state.doc),
      canUndo: _history.canUndo,
      canRedo: _history.canRedo,
      epoch: state.epoch + 1,
    );
    _scheduleSave();
    return true;
  }

  /// 清空本页（T3.5 检查面板用；命令已可撤销）。
  void clearPage() {
    final InkDoc doc = state.doc;
    if (doc.isEmpty) {
      return;
    }
    final List<RemovedStroke> removed = <RemovedStroke>[
      for (int i = 0; i < doc.strokes.length; i++)
        (index: i, stroke: doc.strokes[i]),
    ];
    _applyCommand(ClearPage(removed));
  }

  // ── 内部 ─────────────────────────────────────────────────────────

  void _applyCommand(InkCommand command, {bool structural = true}) {
    _settlePendingErase();
    final InkDoc next = command.apply(state.doc);
    _history.push(command);
    state = InkEditState(
      doc: next,
      canUndo: _history.canUndo,
      canRedo: _history.canRedo,
      epoch: structural ? state.epoch + 1 : state.epoch,
    );
    _scheduleSave();
  }

  /// 把进行中的擦除收成一步撤销（没有就什么也不做）。
  void _settlePendingErase() {
    if (_pendingEraseSteps.isNotEmpty) {
      _history.push(EraseBatch(List<EraseStrokes>.of(_pendingEraseSteps)));
      _pendingEraseSteps.clear();
    }
  }

  /// 只排入调度器，不 await：落盘绝不能挡抬笔（INV-01）。
  ///
  /// 真实保存在 [InkWriter] 里做 500ms 防抖；生命周期/切页由 ReaderPage
  /// 调 `flushAll`。`InkDoc.revision` 保持"这一页变过几次"的本地语义，
  /// 不被磁盘 revision 回填（回填会让它倒退，识别失效判定更不可靠）。
  void _scheduleSave() {
    ref
        .read(inkWriterForKeyProvider(_key))
        .schedule(_key.sessionId, _key.pageIndex, state.doc);
    _recordAnsweredIfAny();
  }

  /// 答题卡画布切题/退出时立刻落盘（独立 writer 不会走 ReaderPage 的 flushAll）。
  Future<void> flushSave() {
    return ref
        .read(inkWriterForKeyProvider(_key))
        .flush(_key.sessionId, _key.pageIndex);
  }

  /// 作答记录去重：`questionId|day`。
  ///
  /// 为什么在这里打点：`_key.sessionId` 对答题卡是 `ans:<sid>:<qid>`，
  /// **每一笔落下都会经过 `_scheduleSave`**——这是"有笔迹更新"唯一可靠的时刻，
  /// 保存按钮、切题、系统返回都只是它的后续动作。放页面里会漏掉"系统返回"。
  ///
  /// 一个进程内一题一天只写一次库：记录页数的是"做过几道题"，
  /// 不是"写过几笔"；去重后每次抬笔都不碰数据库，性能上没有代价。
  static final Set<String> _recordedQuestionDays = <String>{};

  void _recordAnsweredIfAny() {
    try {
      _recordAnsweredInner();
    } on Object {
      // 记录是旁路：任何异常（含测试环境没有 appDependencies）都不能影响落笔。
    }
  }

  void _recordAnsweredInner() {
    final String? questionId = answerQuestionIdOf(
      sessionId: _key.sessionId,
      workbookId: _key.workbookId,
      strokeCount: state.doc.strokeCount,
    );
    if (questionId != null) {
      final String stamp = answerRecordKeyOf(
        questionId,
        DateTime.now().millisecondsSinceEpoch,
      );
      if (!_recordedQuestionDays.add(stamp)) {
        return;
      }
      unawaited(
        ref
            .read(recordServiceProvider)
            .touch(
              workbookId: _key.workbookId,
              questionId: questionId,
              source: RecordSource.ink,
            ),
      );
      return;
    }
    if (state.doc.strokes.isEmpty) {
      return;
    }
    // 收藏重刷：session 带收藏 id（新版还带 attemptId），卷/题要回表查一次。
    // 注意：重刷画布没有 workbookId，所以不能先按 workbookId 空值提前 return
    //（2026-10-26 真机发现：重刷笔迹一直没进记录，时间线看不到）。
    final ({String favoriteId, String? attemptId})? redo =
        parseFavoriteRedoSessionRef(_key.sessionId);
    if (redo == null) {
      return;
    }
    // v8：重刷的记录带**来源**（组卷 / 单题重刷），同一天可以与原卷的记录并存。
    final RedoContext? context = ref.read(redoContextProvider);
    final RecordOrigin origin = context != null && context.isSet
        ? RecordOrigin.set
        : RecordOrigin.redo;
    final String attemptId = context?.attemptId ?? redo.attemptId ?? '';
    final String stamp =
        'fav:${redo.favoriteId}|${RecordTime.dayKey(DateTime.now())}|'
        '${origin.name}|$attemptId';
    if (!_recordedQuestionDays.add(stamp)) {
      return;
    }
    unawaited(
      _recordFavoriteRedo(
        redo.favoriteId,
        origin: origin,
        originTitle: context?.title ?? '',
        attemptId: attemptId,
      ),
    );
  }

  /// 重刷页的一笔也算"做过"：回表拿到这道收藏的来源卷与题号。
  ///
  /// 原卷已删时照样记（[workbookId] 只作为溯源键，`RecordService` 查不到卷名就用快照），
  /// 这正是"记录独立于卷"的用处。
  Future<void> _recordFavoriteRedo(
    String favoriteId, {
    required RecordOrigin origin,
    required String originTitle,
    String attemptId = '',
  }) async {
    try {
      final List<Map<String, Object?>> rows = await ref
          .read(appDependenciesProvider)
          .db
          .raw
          .query(
            'favorite',
            columns: <String>['workbook_id', 'question_id', 'workbook_title'],
            where: 'id = ?',
            whereArgs: <Object?>[favoriteId],
            limit: 1,
          );
      if (rows.isEmpty) {
        return;
      }
      final Map<String, Object?> row = rows.first;
      final String workbookId = (row['workbook_id'] as String?) ?? '';
      final String questionId = (row['question_id'] as String?) ?? '';
      if (questionId.isEmpty) {
        return;
      }
      await ref
          .read(recordServiceProvider)
          .touch(
            workbookId: workbookId,
            questionId: questionId,
            source: RecordSource.redo,
            workbookTitle: (row['workbook_title'] as String?) ?? '',
            origin: origin,
            originTitle: originTitle,
            attemptId: attemptId,
            favoriteId: favoriteId,
          );
    } on Object {
      // 旁路：重刷照常进行。
    }
  }
}
