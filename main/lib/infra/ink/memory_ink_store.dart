import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_store.dart';

/// [InkStore] 的内存实现（**T2.1 临时，T2.4 换 SIF + ink-io isolate**）。
///
/// 为什么现在就写它而不是等 T2.4：墨迹层（T2.1）要通过契约读写笔迹，
/// 让 UI 一开始就依赖接口而不是依赖"某个具体存储"，T2.4 换实现时
/// UI 与 app 层零改动。这也兑现 INV-06"可导出"的路径前提。
///
/// 边界（写进注释，避免后人误用）：
/// - **不跨进程**：杀进程即丢。防丢由 T2.4 的增量落盘负责。
/// - **串行**：同一页的并发 save 由 async 队列天然串行（Dart 单 isolate，
///   await 之间不会交错执行保存逻辑）。
/// - revision 从 0 开始，每次 save +1；load 不存在时返回 [InkDoc.empty]。
class MemoryInkStore implements InkStore {
  final Map<String, InkDoc> _docs = <String, InkDoc>{};

  static String keyOf(String sessionId, int pageIndex) => '$sessionId#$pageIndex';

  @override
  Future<InkDoc> load(String sessionId, int pageIndex) async {
    return _docs[keyOf(sessionId, pageIndex)] ?? InkDoc.empty;
  }

  @override
  Future<int> save(String sessionId, int pageIndex, InkDoc doc) async {
    final InkDoc next = doc.copyWith(revision: doc.revision + 1);
    _docs[keyOf(sessionId, pageIndex)] = next;
    return next.revision;
  }
}
