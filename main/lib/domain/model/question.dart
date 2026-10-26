/// 题目与题目区域（规格 §5.2 `question` / `question_region`）。
///
/// 分工：
/// - [Question] 是"一道题"的身份与元信息（题号、层级、题型、置信度、来源）；
/// - [QuestionRegion] 是这道题**在某一页上占的矩形**，一个跨页题有两行。
///
/// 坐标一律是页面坐标 pt（左上原点、y 向下）。PDF 原生坐标只允许出现在
/// `infra/pdf` 内部。
library;

import 'package:shuaqi/domain/region/edited_question.dart';
import 'package:shuaqi/domain/region/region_rect.dart';

/// 一道题 + 它在本卷各页上的区域（UI 要的就是这个形状）。
class QuestionBundle {
  const QuestionBundle({
    required this.question,
    required this.slices,
    this.locked = false,
  });

  final Question question;

  /// 按页序、按 y 升序。跨页题有多段。
  final List<QuestionSlice> slices;

  /// 任一段被锁定即视为整题锁定（锁定是按题给的，不是按段）。
  final bool locked;

  /// 编辑时用的身份（与覆盖层的 key 一致）。
  String get anchorKey => questionAnchorKey(question.label, slices);
}

/// 一道题的 anchor key（与用户覆盖层里的 key 同一套规则）。
String questionAnchorKey(String? label, List<QuestionSlice> slices) {
  if (slices.isEmpty) {
    return anchorKey(label ?? '', -1, 0);
  }
  return anchorKey(label ?? '', slices.first.pageIndex, slices.first.rect.top);
}

/// 一段区域落在"第几页的哪个矩形"。
class QuestionSlice {
  const QuestionSlice({
    required this.pageIndex,
    required this.rect,
    required this.pageId,
  });

  final int pageIndex;
  final RegionRect rect;

  /// `wb_page.id`（写回 / 编辑时需要）。
  final String pageId;
}

/// 一道题。
class Question {
  const Question({
    required this.id,
    required this.workbookId,
    required this.ordinal,
    required this.level,
    required this.confidence,
    this.label,
    this.parentId,
    this.kind = 'unknown',
    this.stemText,
    this.source = 'rule',
  });

  factory Question.fromRow(Map<String, Object?> row) => Question(
    id: row['id']! as String,
    workbookId: row['workbook_id']! as String,
    ordinal: (row['ordinal']! as num).toInt(),
    level: (row['level'] as num?)?.toInt() ?? 2,
    confidence: (row['confidence'] as num?)?.toDouble() ?? 0,
    label: row['label'] as String?,
    parentId: row['parent_id'] as String?,
    kind: (row['kind'] as String?) ?? 'unknown',
    stemText: row['stem_text'] as String?,
    source: (row['source'] as String?) ?? 'rule',
  );

  final String id;
  final String workbookId;

  /// 全卷文档顺序，1-based（含大题）。
  final int ordinal;

  /// 1 = 大题，2 = 小题。
  final int level;

  /// 0..1，见 `domain/region/confidence.dart`。
  final double confidence;

  /// 题号原文（`12.` `（3）` `一、`）。
  final String? label;

  /// 所属大题（小题才有）。
  final String? parentId;

  /// `choice` / `judge` / `blank` / `essay` / `unknown`。
  final String kind;

  final String? stemText;

  /// `rule` / `layout` / `ocr` / `manual`。
  final String source;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'workbook_id': workbookId,
    'ordinal': ordinal,
    'label': label,
    'level': level,
    'parent_id': parentId,
    'kind': kind,
    'stem_text': stemText,
    'confidence': confidence,
    'source': source,
  };

  @override
  String toString() =>
      'Question(#$ordinal ${label ?? ''} L$level $kind ${(confidence * 100).round()}%)';
}

/// 题目区域（一页一段）。
class QuestionRegion {
  const QuestionRegion({
    required this.id,
    required this.questionId,
    required this.pageId,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.role = 'mixed',
    this.confidence = 0,
    this.locked = false,
  });

  factory QuestionRegion.fromRow(Map<String, Object?> row) => QuestionRegion(
    id: row['id']! as String,
    questionId: row['question_id']! as String,
    pageId: row['page_id']! as String,
    x: (row['x']! as num).toDouble(),
    y: (row['y']! as num).toDouble(),
    width: (row['w']! as num).toDouble(),
    height: (row['h']! as num).toDouble(),
    role: (row['role'] as String?) ?? 'mixed',
    confidence: (row['confidence'] as num?)?.toDouble() ?? 0,
    locked: ((row['locked'] as num?)?.toInt() ?? 0) != 0,
  );

  final String id;
  final String questionId;

  /// `wb_page.id`（**不是**页序）。
  final String pageId;

  final double x;
  final double y;
  final double width;
  final double height;

  /// `mixed` / `stem` / `answer`（第 5 周区分题干与作答区时用）。
  final String role;

  final double confidence;

  /// 锁定的框不参与后续自动重算。
  final bool locked;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'question_id': questionId,
    'page_id': pageId,
    'x': x,
    'y': y,
    'w': width,
    'h': height,
    'role': role,
    'confidence': confidence,
    'locked': locked ? 1 : 0,
  };

  @override
  String toString() =>
      'QuestionRegion($pageId ${x.toStringAsFixed(1)},${y.toStringAsFixed(1)} '
      '${width.toStringAsFixed(1)}×${height.toStringAsFixed(1)})';
}
