import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 笔迹持久化契约（规格 §7）。
///
/// 签名必须保持不变——`app/` 与 `infra/` 两侧都按它编程。
/// 实现由 `infra/ink`（SIF + ink-io isolate，T2.4）提供；本层只有契约，没有实现。
///
/// 语义约定（实现方必须满足）：
/// 1. `save` 返回**新 revision**，且必须原子写（先写临时文件再 rename），
///    中途被杀进程不能留下半个文件。
/// 2. `save` 是串行的：同一 (sessionId, pageIndex) 的并发调用由实现方排队，
///    不允许两个写入交错。
/// 3. `load` 在文件不存在时返回 [InkDoc.empty]，**不抛异常**——
///    "这一页还没写过" 是正常状态，不是错误。
/// 4. 任何方法都不得在主 isolate 做重活：编解码与 zlib 交给 `ink-io`（§4.4）。
abstract interface class InkStore {
  /// 读取某会话某页的笔迹。
  Future<InkDoc> load(String sessionId, int pageIndex);

  /// 落盘并返回新的 revision。
  Future<int> save(String sessionId, int pageIndex, InkDoc doc);
}
