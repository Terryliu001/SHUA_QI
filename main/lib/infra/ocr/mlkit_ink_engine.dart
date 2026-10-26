import 'dart:math' as math;
import 'dart:typed_data';

import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ocr/line_cluster.dart';
import 'package:shuaqi/infra/ocr/ocr_engine.dart';

/// 本地手写识别：Google ML Kit Digital Ink Recognition。
///
/// 只负责"笔画 → 文本"；不做归属、判题，也不认识题目。
/// 公式/符号识别不准时返回空文本，由上层按"待复核/只留原图"降级。
///
/// 模型是**按语言远程下载**的（不是打进 APK 的 ONNX）：
/// - 首次使用会触发下载，可能耗时/需要网络；
/// - 下载失败、无 GMS、语言包不可用 → [warmUp] 返回 false，调用方降级，不抛。
class MlKitInkEngine implements OcrEngine {
  MlKitInkEngine({this.language = 'zh-Hans'});

  /// BCP-47。中文手写先走简体；模型不可用时再试英文。
  final String language;

  final DigitalInkRecognizerModelManager _models =
      DigitalInkRecognizerModelManager();

  DigitalInkRecognizer? _recognizer;
  String? _activeLanguage;
  bool _warmed = false;

  @override
  String get name => 'ink_mlkit';

  @override
  Future<bool> warmUp() async {
    if (_warmed) {
      return _recognizer != null;
    }
    _warmed = true;
    for (final String code in <String>[language, 'en-US']) {
      try {
        bool downloaded = await _models.isModelDownloaded(code);
        if (!downloaded) {
          downloaded = await _models.downloadModel(
            code,
            isWifiRequired: false,
          );
        }
        if (downloaded) {
          _activeLanguage = code;
          _recognizer = DigitalInkRecognizer(languageCode: code);
          return true;
        }
      } on Object {
        // 继续尝试下一个语言；全部失败交给调用方降级。
      }
    }
    return false;
  }

  @override
  Future<OcrOutput> recognizeStrokes(
    List<InkStroke> strokes, {
    required int revision,
  }) async {
    if (strokes.isEmpty) {
      return OcrOutput(text: '', confidence: 1, revision: revision);
    }
    if (!await warmUp()) {
      return OcrOutput(text: '', confidence: 0, revision: revision);
    }
    final DigitalInkRecognizer? recognizer = _recognizer;
    if (recognizer == null) {
      return OcrOutput(text: '', confidence: 0, revision: revision);
    }

    final List<InkLine> lines = clusterInkLines(strokes);
    if (lines.isEmpty) {
      // 只有荧光笔：明确"无笔迹"，不是识别失败。
      return OcrOutput(text: '', confidence: 1, revision: revision);
    }

    final List<OcrLine> out = <OcrLine>[];
    bool truncated = false;
    for (final InkLine line in lines) {
      final Ink ink = _toMlKitInk(line);
      if (ink.strokes.isEmpty) {
        continue;
      }
      try {
        final List<RecognitionCandidate> candidates = await recognizer.recognize(
          ink,
          context: DigitalInkRecognitionContext(
            writingArea: WritingArea(
              width: math.max(line.bounds.width + 24, 32),
              height: math.max(line.bounds.height + 16, 24),
            ),
          ),
        );
        if (candidates.isEmpty) {
          continue;
        }
        final RecognitionCandidate best = candidates.first;
        String text = best.text.trim();
        if (text.isEmpty) {
          continue;
        }
        if (text.length > 300) {
          text = text.substring(0, 300);
          truncated = true;
        }
        out.add(
          OcrLine(
            text: text,
            confidence: confidenceFromMlKitScore(best.score),
            top: line.bounds.top,
            bottom: line.bounds.top + line.bounds.height,
          ),
        );
      } on Object {
        // 单行失败不拖垮整题；继续识别下一行。
      }
    }

    if (out.isEmpty) {
      return OcrOutput(text: '', confidence: 0, revision: revision);
    }
    final String text = out.map((OcrLine line) => line.text).join('\n');
    int chars = 0;
    double weighted = 0;
    for (final OcrLine line in out) {
      final int n = line.text.length;
      chars += n;
      weighted += line.confidence * n;
    }
    return OcrOutput(
      text: text,
      confidence: chars == 0 ? 0 : weighted / chars,
      lines: out,
      truncated: truncated,
      revision: revision,
    );
  }

  @override
  Future<OcrOutput> recognizeImage(Uint8List png, {required int revision}) async {
    // 引擎 A 只处理笔画；图像走引擎 B，不在本类假装支持。
    return OcrOutput(text: '', confidence: 0, revision: revision);
  }

  @override
  Future<void> dispose() async {
    await _recognizer?.close();
    _recognizer = null;
    _activeLanguage = null;
    _warmed = false;
  }

  String? get activeLanguage => _activeLanguage;

  Ink _toMlKitInk(InkLine line) {
    final Ink ink = Ink();
    for (final InkStroke stroke in line.strokes) {
      final Stroke out = Stroke();
      out.points = <StrokePoint>[
        for (final InkPoint point in stroke.points)
          StrokePoint(x: point.x, y: point.y, t: point.t),
      ];
      if (out.points.isNotEmpty) {
        ink.strokes.add(out);
      }
    }
    return ink;
  }
}

/// ML Kit 的 score 越小越可信（没有固定的 0..1 概率）。
///
/// 用 sigmoid 映射到 0..1：score=0 → 0.5，-1 → 0.73，-2 → 0.88。
/// 只用于"是否低置信需要复核"，不拿它当严格概率。
double confidenceFromMlKitScore(double score) {
  if (!score.isFinite) {
    return 0.5;
  }
  final double value = 1 / (1 + math.exp(score));
  return value.clamp(0.05, 0.99);
}
