import 'dart:typed_data';

/// 公式识别引擎（引擎 C）契约（规格 §7、§6.7）。
///
/// 与 [OcrEngine] 分开定义，因为它的输入输出都不同：
/// 输入是**一行**裁好的图，输出是 LaTeX 而不是文本。硬塞进 OcrEngine 会让两边都别扭。
abstract interface class FormulaEngine {
  /// 模型是否已下载/加载完毕。false 时调用方必须静默降级为「裁图 + 公式识别未就绪」，
  /// **不许弹窗、不许重试**（§6.7.6）。
  Future<bool> isReady();

  /// 加载模型并跑一次空推理（第一次推理包含 session 初始化，很慢，不能计进耗时样本）。
  Future<void> warmUp();

  /// 识别一行。需在 `FormulaLineImage` 已预处理（96px 高、白底黑字、3 通道）之后调用。
  /// [revision] 用于回写时的版本校验（INV-02）。
  Future<FormulaResult> recognizeLine(
    FormulaLineImage image, {
    required int revision,
  });

  /// 空闲 5 分钟或内存压力时卸载（§5.6：引擎 B/C 互斥，同一时刻只有一个驻留）。
  Future<void> unload();
}

/// 待识别的一行公式图。**预处理已经做完**，引擎不做裁剪也不做缩放。
class FormulaLineImage {
  const FormulaLineImage({
    required this.png,
    required this.lineIndex,
    required this.cropPath,
  });

  /// PNG 字节。高度固定 96px，最长边 ≤1024px，灰度复制为 3 通道，四周补 8px 白（§6.7.4）。
  final Uint8List png;

  /// 行号，回写 `formula_item.line_index`（§5.2 UNIQUE(block_id, line_index)）。
  final int lineIndex;

  /// 行裁图在 Vault 里的相对路径。渲染失败时 UI 靠它显示"你写的原样"。
  final String cropPath;
}

/// 一次公式识别的结果。
class FormulaResult {
  const FormulaResult({
    required this.latex,
    required this.rawLatex,
    required this.valid,
    required this.confidence,
    this.errorCode,
  });

  /// 失败结果。[valid] 为 false，[latex] 为空；调用方一律显示裁图，**不许渲染空字符串**。
  const FormulaResult.failed({
    required this.errorCode,
    required this.rawLatex,
    this.confidence = 0,
  }) : latex = '',
       valid = false;

  /// 规范化后的 LaTeX（无 `$` 定界符）。[valid] 为 false 时是空串。
  final String latex;

  /// 模型原始输出。**必须保留**，否则出了问题无法归因，也无法回滚（§5.2 `raw_latex`）。
  final String rawLatex;

  /// 是否可渲染。false 时 UI 一律显示裁图（INV-07）。
  final bool valid;

  /// exp(mean(logprob))。
  final double confidence;

  /// 见 [FormulaErrorCodes]。
  final String? errorCode;

  bool get isFailure => !valid;
}

/// 错误码枚举值。用字符串常量而不是 enum，是为了能原样写进 `formula_item` / `ocr_run.error`。
abstract final class FormulaErrorCodes {
  static const String timeout = 'timeout';
  static const String empty = 'empty';
  static const String invalidLatex = 'invalid_latex';
  static const String oom = 'oom';
  static const String modelMissing = 'model_missing';
}
