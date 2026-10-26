/// 收藏夹模型（纯 Dart）。
///
/// ## 为什么是「独立快照」而不是引用
/// 收藏要满足两件引用做不到的事：
/// 1. **跨卷**：收藏的题来自不同卷，要在一个列表里混排、检索；
/// 2. **原卷删除后仍保留**：`question`/`question_region`/`session` 都随卷 CASCADE 删掉，
///    收藏必须自己存一份题面/笔迹/AI 对话，所以 [Favorite] **不设外键**指向卷或题，
///    只留 [questionId]/[workbookId] 做溯源，[sourceDeleted] 标记来源卷已删。
///
/// 快照文件（题面图/作答图/对话/判题/答案）在 `favorites/<id>/`，由
/// `app/favorite/favorite_store.dart` 落盘；本文件只承载「元信息」这一张表。
library;

import 'dart:convert';

import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/region/region_rect.dart';

/// 一道被收藏的题。
class Favorite {
  const Favorite({
    required this.id,
    required this.questionId,
    required this.workbookId,
    required this.workbookTitle,
    required this.label,
    required this.ordinal,
    required this.kind,
    required this.stemText,
    required this.pageIndex,
    required this.rect,
    required this.knowledgeTags,
    required this.verdict,
    required this.sourceDeleted,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Favorite.fromRow(Map<String, Object?> row) => Favorite(
    id: row['id']! as String,
    questionId: (row['question_id'] as String?) ?? '',
    workbookId: (row['workbook_id'] as String?) ?? '',
    workbookTitle: (row['workbook_title'] as String?) ?? '',
    label: (row['label'] as String?) ?? '',
    ordinal: (row['ordinal'] as num?)?.toInt() ?? 0,
    kind: (row['kind'] as String?) ?? 'unknown',
    stemText: (row['stem_text'] as String?) ?? '',
    pageIndex: (row['page_index'] as num?)?.toInt() ?? 0,
    rect: _rectFrom(row['rect'] as String?),
    knowledgeTags: KnowledgeTags.decode(row['knowledge_tags'] as String?),
    verdict: AnswerVerdict.decode(row['verdict'] as String?),
    sourceDeleted: ((row['source_deleted'] as num?)?.toInt() ?? 0) != 0,
    createdAt: (row['created_at']! as num).toInt(),
    updatedAt: (row['updated_at']! as num).toInt(),
  );

  final String id;

  /// 源题 id（溯源用；原卷删除后该 id 在 question 表里已不存在）。
  final String questionId;

  /// 源卷 id（溯源用；卷删除后仍保留此值，但 `workbook` 表已无此行）。
  final String workbookId;

  /// 卷名快照（卷删除后仍有名字可显示）。
  final String workbookTitle;

  /// 题号原文（`12.` `（3）`）。
  final String label;

  final int ordinal;

  /// `choice` / `judge` / `blank` / `essay` / `unknown`。
  final String kind;

  final String stemText;

  /// 题面所在页（0-based，快照 rect 对应的页）。
  final int pageIndex;

  /// 题面区域（页面坐标 pt）。收藏那一刻定格。
  final RegionRect rect;

  /// 知识点标签（自由标签，AI 归纳或手动改）。
  final List<String> knowledgeTags;

  /// 收藏时的判题结论（`AnswerVerdict`）。
  final AnswerVerdict verdict;

  /// 来源卷是否已删除。删除后「回到出处」不可用，看题页走快照。
  final bool sourceDeleted;

  /// UTC 毫秒。
  final int createdAt;

  /// UTC 毫秒。最近一次改动（改知识点/判题等）时间，收藏夹按它排序。
  final int updatedAt;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'question_id': questionId,
    'workbook_id': workbookId,
    'workbook_title': workbookTitle,
    'label': label,
    'ordinal': ordinal,
    'kind': kind,
    'stem_text': stemText,
    'page_index': pageIndex,
    'rect': jsonEncode(rect.toJson()),
    'knowledge_tags': KnowledgeTags.encode(knowledgeTags),
    'verdict': verdict.name,
    'source_deleted': sourceDeleted ? 1 : 0,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  Favorite copyWith({
    String? workbookTitle,
    String? label,
    String? kind,
    String? stemText,
    RegionRect? rect,
    List<String>? knowledgeTags,
    AnswerVerdict? verdict,
    bool? sourceDeleted,
    int? updatedAt,
  }) => Favorite(
    id: id,
    questionId: questionId,
    workbookId: workbookId,
    workbookTitle: workbookTitle ?? this.workbookTitle,
    label: label ?? this.label,
    ordinal: ordinal,
    kind: kind ?? this.kind,
    stemText: stemText ?? this.stemText,
    pageIndex: pageIndex,
    rect: rect ?? this.rect,
    knowledgeTags: knowledgeTags ?? this.knowledgeTags,
    verdict: verdict ?? this.verdict,
    sourceDeleted: sourceDeleted ?? this.sourceDeleted,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  String toString() => 'Favorite($id, #$ordinal $label "$workbookTitle")';
}

/// 收藏题的知识点标签（自由标签，与书架的 `WorkbookTags` 同思路但独立）。
///
/// 规则：逗号分隔，忽略首尾空白与空项；**去重**；单个最长 20 字、最多 5 个。
abstract final class KnowledgeTags {
  static const String separator = ',';

  static const int maxCount = 5;
  static const int maxLength = 20;

  static List<String> parse(String raw) {
    final List<String> out = <String>[];
    for (final String chunk in raw.split(RegExp(r'[,，、;；]'))) {
      final String t = chunk.trim();
      if (t.isEmpty || out.contains(t)) {
        continue;
      }
      out.add(t.length > maxLength ? t.substring(0, maxLength) : t);
      if (out.length >= maxCount) {
        break;
      }
    }
    return out;
  }

  static List<String> decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const <String>[];
    }
    return raw
        .split(separator)
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
  }

  static String encode(List<String> tags) => tags.join(separator);
}

/// 一份「组卷冲刷」的命名题集（T8.4）。成员有序，在 `favorite_set_item` 表。
///
/// [itemCount] 是**查询时带出来的计数**（`listSets` 用子查询一次算好），
/// 不落 `favorite_set` 表——成员增删本来就只在 `favorite_set_item` 一处，
/// 冗余计数迟早对不上。
class FavoriteSet {
  const FavoriteSet({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.itemCount = 0,
  });

  factory FavoriteSet.fromRow(Map<String, Object?> row) => FavoriteSet(
    id: row['id']! as String,
    name: (row['name'] as String?) ?? '',
    createdAt: (row['created_at']! as num).toInt(),
    updatedAt: (row['updated_at']! as num).toInt(),
    itemCount: (row['item_count'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String name;
  final int createdAt;
  final int updatedAt;

  /// 卷内题数（来自 `listSets` 的 `item_count`；单查 `byId` 时为 0）。
  final int itemCount;

  /// 题集名：空名不合法（UI 侧拦），这里只兜底成「未命名题集」。
  String get displayName => name.trim().isEmpty ? '未命名题集' : name;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'name': name,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  FavoriteSet copyWith({String? name, int? updatedAt, int? itemCount}) =>
      FavoriteSet(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        itemCount: itemCount ?? this.itemCount,
      );
}

RegionRect _rectFrom(String? raw) {
  if (raw == null || raw.isEmpty) {
    return RegionRect.empty;
  }
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return RegionRect.empty;
    }
    return RegionRect.fromJson(decoded.cast<String, Object?>());
  } on Object {
    return RegionRect.empty;
  }
}
