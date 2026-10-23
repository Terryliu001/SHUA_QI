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

/// 一次载入的结果（给 UI 的明确提示，不塞进 [InkDoc]）。
enum InkLoadIssue {
  /// 正常。
  none,

  /// 主文件坏了/不存在，但 `.bak` 可用且已恢复。
  recoveredFromBackup,

  /// 主文件与 `.bak` 都不可用；这一页按空页处理，原文件保留。
  corrupt,
}

/// 可选的"载入问题报告"能力。
///
/// 不改 [InkStore] 契约（规格要求签名稳定）：SIF 实现额外实现本接口，
/// `InkEditController` 用 `is` 探测。内存实现不实现 → 永远没有 issue。
abstract interface class InkIssueReporter {
  /// 取走（并清空）某页最近一次载入的问题。没有返回 [InkLoadIssue.none]。
  InkLoadIssue takeLoadIssue(String sessionId, int pageIndex);
}
