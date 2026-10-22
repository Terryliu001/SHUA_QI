import 'dart:typed_data';

import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 手写/印刷识别引擎的统一契约（规格 §7）。
///
/// 三个引擎（A 笔画级 / B 图像级 / C 公式）共享这一个接口，
/// 由 `app/ocr/OcrScheduler` 决定"什么时候、用哪个、跑哪些笔画"。
/// 引擎自己**不做归属、不做判题、不认识题目**（§4.2 禁止项）。
///
/// 实现方必须满足：
/// 1. [recognizeStrokes] / [recognizeImage] 永远可被取消；取消不是错误，返回空 [OcrOutput] 即可。
/// 2. 三引擎共享一个模型槽位（§6.2 规则 2）：同一时刻只允许一个 ONNX session 驻留，
///    互斥由调度器保证，引擎只负责 [dispose] 时真正释放。
/// 3. 结果不带 `revision` 以外的版本信息；过期判断由调用方用返回的 revision 比对（INV-02）。
abstract interface class OcrEngine {
  /// `ink_mlkit` | `onnx_ppocr` | `onnx_formula`。写进 `ocr_run.engine`，不要随手改名。
  String get name;

  /// 预热（加载模型、触发 ML Kit 语言包检查）。返回 false 表示本机不可用，
  /// 调用方据此降级，**不是异常**（INV-02）。
  Future<bool> warmUp();

  /// 笔画级识别（引擎 A）。
  Future<OcrOutput> recognizeStrokes(
    List<InkStroke> strokes, {
    required int revision,
  });

  /// 图像级识别（引擎 B）。输入是已裁剪好的 PNG。
  Future<OcrOutput> recognizeImage(Uint8List png, {required int revision});

  Future<void> dispose();
}

/// 一行的识别结果。行聚类之后才会有多个；引擎 A 内部自己完成聚类（§6.3）。
class OcrLine {
  const OcrLine({
    required this.text,
    required this.confidence,
    required this.top,
    required this.bottom,
  });

  final String text;

  /// 0..1。低于 0.65 一律按 `unclear` 处理（INV-05），判断在判题层，不在引擎。
  final double confidence;

  /// 行在页面坐标里的上下边界（pt），用于后续按行裁图与公式行判别。
  final double top;
  final double bottom;

  double get height => bottom - top;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'conf': confidence,
    'top': top,
    'bottom': bottom,
  };
}

/// 一次识别的完整输出。
class OcrOutput {
  const OcrOutput({
    required this.text,
    required this.confidence,
    this.lines = const <OcrLine>[],
    this.truncated = false,
    this.revision = 0,
  });

  /// 空结果。引擎失败、被取消、或"只有荧光笔"都返回它——**用空表示无，不用异常**。
  static const OcrOutput empty = OcrOutput(text: '', confidence: 0);

  /// 整段文本，行间以 `\n` 连接（§6.3 第 5 步）。
  final String text;

  /// 各行 score 按字符数加权（§6.3 第 5 步）。
  final double confidence;

  final List<OcrLine> lines;

  /// 单行超过 300 字被截断时置 true（§6.3 异常分支）。
  final bool truncated;

  /// 产出这个结果时所基于的笔迹版本号，供调用方校验是否已过期。
  final int revision;

  bool get isEmpty => text.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'conf': confidence,
    'truncated': truncated,
    'revision': revision,
    'lines': lines.map((OcrLine line) => line.toJson()).toList(),
  };
}
