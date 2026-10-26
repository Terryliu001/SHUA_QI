import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/region/region_rect.dart';

/// 答题卡手写画布的虚拟页面尺寸（pt）。
///
/// 答题卡不依赖 PDF 页：每道题给一块固定比例的空白纸，所有题共用同一套
/// SIF 编码/识别管线。比例取 5:3（宽:高），横屏平板上正好放下"题面 + 作答区"。
abstract final class AnswerCanvas {
  static const double widthPt = 1000;
  static const double heightPt = 600;
  static const double aspect = widthPt / heightPt;
}

/// 一道题的「作答框」与作答识别结果（纯 Dart）。
///
/// 为什么要单独一个模型，而不是复用 `question_region`：
/// - 题目区域是**切题结果**（自动算法所有）；作答框是**用户/识别用的派生区域**，
///   默认跟随题目区域，但允许单独缩小、移动；
/// - 同一道题可能跨页，题目区域有多段；作答框只有一个（默认取最后一段；
///   答案通常写在最后一段的空白处）；
/// - 后续交卷、OCR、判题都按 `questionId` 取作答框，不依赖 anchor key
///   （anchor 会随切题/拖动变化）。
class AnswerSheetEntry {
  const AnswerSheetEntry({
    required this.questionId,
    required this.pageIndex,
    required this.rect,
    this.regionSource = AnswerRegionSource.auto,
    this.ocrText = '',
    this.ocrConfidence = 0,
    this.ocrEngine = '',
    this.cropPath,
    this.updatedAt = 0,
    this.ocrAt = 0,
  });

  /// 默认：**整道题干区域**都算作答区。
  ///
  /// 为什么不默认只取下半部分：不同题型（选择题/填空/解答）的作答位置差异太大，
  /// 猜错了会吞掉用户写的字；整题默认至少不会漏，用户再按需缩小。
  factory AnswerSheetEntry.defaultFor(QuestionBundle bundle) {
    if (bundle.slices.isEmpty) {
      return AnswerSheetEntry(
        questionId: bundle.question.id,
        pageIndex: 0,
        rect: RegionRect.empty,
      );
    }
    final QuestionSlice slice = bundle.slices.last;
    return AnswerSheetEntry(
      questionId: bundle.question.id,
      pageIndex: slice.pageIndex,
      rect: slice.rect,
    );
  }

  factory AnswerSheetEntry.fromJson(Map<String, Object?> json) {
    return AnswerSheetEntry(
      questionId: (json['question_id'] as String?) ?? '',
      pageIndex: (json['page'] as num?)?.toInt() ?? 0,
      rect: json['rect'] is Map
          ? RegionRect.fromJson((json['rect']! as Map).cast<String, Object?>())
          : RegionRect.empty,
      regionSource: AnswerRegionSource.decode(json['region_source'] as String?),
      ocrText: (json['ocr_text'] as String?) ?? '',
      ocrConfidence: (json['ocr_conf'] as num?)?.toDouble() ?? 0,
      ocrEngine: (json['ocr_engine'] as String?) ?? '',
      cropPath: json['crop_path'] as String?,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      ocrAt: (json['ocr_at'] as num?)?.toInt() ?? 0,
    );
  }

  final String questionId;

  /// 作答框所在页（0-based）。
  final int pageIndex;

  /// 作答框（页面坐标 pt）。默认为整题区域。
  final RegionRect rect;

  /// 这个框是自动跟随题目，还是用户手调过。
  final AnswerRegionSource regionSource;

  /// 本地 OCR 文本；空串 = 未识别/没有文字。
  final String ocrText;

  final double ocrConfidence;

  /// `ink_mlkit` / `onnx_ppocr` / `manual` / 空 = 未识别。
  final String ocrEngine;

  /// 作答原图在 Vault 里的相对路径；null = 还没生成。
  final String? cropPath;

  final int updatedAt;

  /// 最后一次识别完成的时间（ms）。0 = 从没识别过。
  ///
  /// 为什么要跟 [updatedAt] 分开：改作答框时 [updatedAt] 也会变，
  /// 用它判断"识别结果是否过期"会永远为真。拆开后 [ocrStale] 才能表达
  /// "框改过了、文字还是旧框里识别的"这件具体的事（2026-10-24 用户第 5 条）。
  final int ocrAt;

  bool get hasText => ocrText.trim().isNotEmpty;

  bool get hasCrop => cropPath != null && cropPath!.isNotEmpty;

  bool get manuallyAdjusted => regionSource == AnswerRegionSource.manual;

  /// 识别结果比作答框旧 → 需要重识别（展开答题情况时后台自动跑）。
  bool get ocrStale => hasText && ocrAt > 0 && updatedAt > ocrAt;

  AnswerSheetEntry copyWith({
    int? pageIndex,
    RegionRect? rect,
    AnswerRegionSource? regionSource,
    String? ocrText,
    double? ocrConfidence,
    String? ocrEngine,
    String? cropPath,
    int? updatedAt,
    int? ocrAt,
    bool clearCrop = false,
  }) {
    return AnswerSheetEntry(
      questionId: questionId,
      pageIndex: pageIndex ?? this.pageIndex,
      rect: rect ?? this.rect,
      regionSource: regionSource ?? this.regionSource,
      ocrText: ocrText ?? this.ocrText,
      ocrConfidence: ocrConfidence ?? this.ocrConfidence,
      ocrEngine: ocrEngine ?? this.ocrEngine,
      cropPath: clearCrop ? null : (cropPath ?? this.cropPath),
      updatedAt: updatedAt ?? this.updatedAt,
      ocrAt: ocrAt ?? this.ocrAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'question_id': questionId,
    'page': pageIndex,
    'rect': rect.toJson(),
    'region_source': regionSource.name,
    'ocr_text': ocrText,
    'ocr_conf': ocrConfidence,
    'ocr_engine': ocrEngine,
    'crop_path': cropPath,
    'updated_at': updatedAt,
    'ocr_at': ocrAt,
  };
}

/// 作答框来源。`auto` 跟随题目区域；`manual` 用户手调过，不再跟随。
enum AnswerRegionSource {
  auto,
  manual;

  static AnswerRegionSource decode(String? raw) {
    for (final AnswerRegionSource source in values) {
      if (source.name == raw) {
        return source;
      }
    }
    return AnswerRegionSource.auto;
  }
}

/// 一卷的作答框/识别结果集合，按 `questionId` 存。
class AnswerSheetData {
  const AnswerSheetData(this.entries);

  static const AnswerSheetData empty = AnswerSheetData(
    <String, AnswerSheetEntry>{},
  );

  final Map<String, AnswerSheetEntry> entries;

  bool get isEmpty => entries.isEmpty;

  AnswerSheetEntry? storedFor(String questionId) => entries[questionId];

  /// 取这道题的作答框：有手调结果用手调的，否则默认整题。
  AnswerSheetEntry regionFor(QuestionBundle bundle) {
    return entries[bundle.question.id] ?? AnswerSheetEntry.defaultFor(bundle);
  }

  AnswerSheetData withEntry(AnswerSheetEntry entry) {
    final Map<String, AnswerSheetEntry> next = Map<String, AnswerSheetEntry>.of(
      entries,
    )..[entry.questionId] = entry;
    return AnswerSheetData(next);
  }

  AnswerSheetData without(String questionId) {
    if (!entries.containsKey(questionId)) {
      return this;
    }
    final Map<String, AnswerSheetEntry> next = Map<String, AnswerSheetEntry>.of(
      entries,
    )..remove(questionId);
    return AnswerSheetData(next);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'answers': <Map<String, Object?>>[
      for (final AnswerSheetEntry entry in entries.values) entry.toJson(),
    ],
  };

  factory AnswerSheetData.fromJson(Map<String, Object?>? json) {
    final Object? raw = json?['answers'];
    if (raw is! List) {
      return empty;
    }
    final Map<String, AnswerSheetEntry> entries = <String, AnswerSheetEntry>{};
    for (final Object? item in raw) {
      if (item is! Map) {
        continue;
      }
      final AnswerSheetEntry entry = AnswerSheetEntry.fromJson(
        item.cast<String, Object?>(),
      );
      if (entry.questionId.isEmpty || entry.rect.isEmpty) {
        continue;
      }
      entries[entry.questionId] = entry;
    }
    return AnswerSheetData(entries);
  }
}
