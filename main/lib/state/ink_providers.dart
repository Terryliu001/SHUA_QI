import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_store.dart';
import 'package:shuaqi/infra/ink/memory_ink_store.dart';

/// 笔迹存储（T2.1 内存实现；T2.4 换 SIF 时只改这一行）。
final Provider<InkStore> inkStoreProvider = Provider<InkStore>((Ref ref) {
  return MemoryInkStore();
});

/// 一页笔迹的定位键。做成值对象而不是 `'$sessionId#$pageIndex'` 字符串：
/// family 的 arg 直接当 Map 键用，字符串拼接要小心分隔符碰撞，
/// 值对象靠结构相等，编译期就能发现漏字段。
class InkPageKey {
  const InkPageKey(this.sessionId, this.pageIndex);

  final String sessionId;
  final int pageIndex;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is InkPageKey &&
            other.sessionId == sessionId &&
            other.pageIndex == pageIndex;
  }

  @override
  int get hashCode => Object.hash(sessionId, pageIndex);
}

/// 一页的笔迹状态（Notifier + family）。
///
/// 两条设计约束：
/// 1. **加载是异步的，但 UI 不能等**：`build()` 先返回 [InkDoc.empty]
///    （这一页还没读过就是空的，合法初始态），加载完静默替换。
/// 2. **commit 先改内存再落盘**：抬笔到上屏之间只有"点追加 + 通知"，
///    落盘走异步（INV-01/INV-02）。revision 以落盘返回为准回填——
///    W4 的识别调度要拿它做版本校验，不能让内存里的版本号与磁盘打架。
final NotifierProvider<InkDocController, InkDoc> Function(InkPageKey)
inkDocProvider = NotifierProvider.family<InkDocController, InkDoc, InkPageKey>(
  InkDocController.new,
);

class InkDocController extends Notifier<InkDoc> {
  InkDocController(this._key);

  final InkPageKey _key;

  /// 落盘代次：每次开始保存 +1。保存完成时如果代次没变（期间没有新笔画），
  /// 才把磁盘返回的 revision 回填到 state——否则会被旧保存覆盖新状态。
  int _saveGeneration = 0;

  @override
  InkDoc build() {
    unawaited(_load());
    return InkDoc.empty;
  }

  Future<void> _load() async {
    final InkDoc loaded = await ref
        .read(inkStoreProvider)
        .load(_key.sessionId, _key.pageIndex);
    if (!ref.mounted) {
      return;
    }
    state = loaded;
  }

  /// 追加一笔（抬笔时调）。返回新 revision（内存版本）。
  Future<int> commit(InkStroke stroke) async {
    state = state.append(stroke);
    unawaited(_save());
    return state.revision;
  }

  Future<void> _save() async {
    final int generation = ++_saveGeneration;
    final InkDoc snapshot = state;
    final int revision = await ref
        .read(inkStoreProvider)
        .save(_key.sessionId, _key.pageIndex, snapshot);
    if (!ref.mounted || generation != _saveGeneration) {
      // 期间又有新笔画：那次保存会带回更新的版本号，这次不回填
      return;
    }
    state = state.copyWith(revision: revision);
  }
}
