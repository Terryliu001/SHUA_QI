import 'dart:async';
import 'dart:developer' as developer;

import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_store.dart';

/// 落盘调度器（T2.4）：**抬笔后 500ms 防抖、同页只保留最后一次**。
///
/// 为什么不在 `InkEditController` 里直接 `await store.save()`：
/// 每抬一笔就整页编码一次，写满的页会变成 O(n²) 的写放大；
/// 而落盘又是纯 IO，绝不能挡落笔路径（INV-01）。
///
/// 生命周期：
/// - 每次编辑 `schedule`（重置该页定时器）；
/// - 500ms 无人编辑 → 写一次；
/// - `ReaderPage` 在 paused/detached、退出、切页时调用 `flush` / `flushAll`；
/// - 保存失败**不丢内存里的 doc**：留在 `_pending`，下次编辑/下次 flush 再试。
class InkWriter {
  InkWriter({
    required this.store,
    this.debounce = const Duration(milliseconds: 500),
  });

  final InkStore store;

  /// 防抖时长。测试里传 [Duration.zero] 即可同步触发。
  final Duration debounce;

  final Map<String, _Pending> _pending = <String, _Pending>{};
  final Map<String, Timer> _timers = <String, Timer>{};
  final Map<String, Future<void>> _inflight = <String, Future<void>>{};
  bool _disposed = false;

  /// 排入一页的最新快照。同页多次调用只保留最后一次。
  void schedule(String sessionId, int pageIndex, InkDoc doc) {
    if (_disposed) {
      return;
    }
    final String key = _keyOf(sessionId, pageIndex);
    _pending[key] = _Pending(sessionId, pageIndex, doc);
    _timers.remove(key)?.cancel();
    _timers[key] = Timer(debounce, () {
      _timers.remove(key);
      unawaited(_flushKey(key));
    });
  }

  /// 立刻落一页（切页 / 用户主动退出时）。
  Future<void> flush(String sessionId, int pageIndex) {
    final String key = _keyOf(sessionId, pageIndex);
    _timers.remove(key)?.cancel();
    return _flushKey(key);
  }

  /// 落掉所有待写页（生命周期回调 / 关闭阅读器时）。
  ///
  /// 会等待正在写的任务结束；如果等待期间又来了新快照，调用方应再 flush 一次
  /// （生命周期回调是幂等的，多调一次没有副作用）。
  Future<void> flushAll() async {
    for (final Timer timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final String key in _pending.keys.toList(growable: false)) {
      await _flushKey(key);
    }
    await Future.wait(_inflight.values.toList(growable: false));
  }

  /// 只释放定时器；不隐式 flush（调用方必须先 `flushAll`）。
  void dispose() {
    _disposed = true;
    for (final Timer timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  Future<void> _flushKey(String key) async {
    final _Pending? pending = _pending.remove(key);
    if (pending == null) {
      await _inflight[key];
      return;
    }
    final Future<void>? previous = _inflight[key];
    final Completer<void> completer = Completer<void>();
    _inflight[key] = completer.future;
    if (previous != null) {
      await previous;
    }
    try {
      await store.save(pending.sessionId, pending.pageIndex, pending.doc);
    } on Object catch (error, stack) {
      // 保存失败：把快照放回去，下一次编辑/flush 再试。绝不向上抛
      // （生命周期回调里抛异常会变成未捕获错误）。
      _pending.putIfAbsent(
        key,
        () => _Pending(pending.sessionId, pending.pageIndex, pending.doc),
      );
      developer.log(
        'SIF 保存失败（$key）：$error',
        name: 'shuaqi.ink',
        error: error,
        stackTrace: stack,
      );
    } finally {
      _inflight.remove(key)?.ignore();
      completer.complete();
    }
  }

  static String _keyOf(String sessionId, int pageIndex) =>
      '$sessionId#$pageIndex';
}

class _Pending {
  const _Pending(this.sessionId, this.pageIndex, this.doc);

  final String sessionId;
  final int pageIndex;
  final InkDoc doc;
}
