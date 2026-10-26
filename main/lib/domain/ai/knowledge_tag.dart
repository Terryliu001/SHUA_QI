/// 知识点 AI 归纳（T8.5）：输入模型 + 提示词 + 宽容解析（纯 Dart）。
///
/// 为什么要"批量一次请求"而不是每题一个请求：
/// - 收藏夹的「未归纳」通常十几道，逐题发就是十几次网络往返与十几次费用；
/// - 归纳是**弱判断**（一道题可能属于两三个知识点），批量看同一批题反而更一致；
/// - 输出只有标签名，失败重试的代价也小。
///
/// ## 键的稳定性（2026-10-25 修）
/// 收藏 id 是 ULID（26 位），模型抄写时很容易漏字/改大小写/换成题号，导致
/// "返回了标签但对不上题"。所以提示词让模型用**短键 `q1..qN`**，解析时再按
/// 顺序映射回真实 id；同时兼容模型直接抄 id / 用「第 3 题」做键的情况。
library;

import 'package:shuaqi/domain/ai/ai_response.dart';
import 'package:shuaqi/domain/model/favorite.dart';

/// 一道待归纳的题（只带归纳需要的字段，不塞整份收藏对象）。
class KnowledgeTagItem {
  const KnowledgeTagItem({
    required this.id,
    required this.label,
    required this.workbookTitle,
    required this.kind,
    this.stemText = '',
    this.ordinal = 0,
  });

  final String id;
  final String label;
  final String workbookTitle;
  final String kind;
  final String stemText;

  /// 题目序号（用于把模型写的「第 3 题」映射回来）。
  final int ordinal;

  /// 题干截断：标签判断不需要整题，1500 字足够，也控制 token。
  String get clippedStem => stemText.trim().length <= 1500
      ? stemText.trim()
      : '${stemText.trim().substring(0, 1500)}…';
}

/// 归纳任务的 system（严格 JSON，便于落库）。
String knowledgeTagSystem() => '''
你是「知识点归纳助手」。用户会给你一批收藏题（每题有短键 qN、题号、来源卷、题型、题干文本）。
请为每道题归纳 1–3 个**知识点标签**，要求：
1. 标签是学科通用短词，2–8 个字，例如：极限、导数、三角函数、立体几何、概率、完形填空、阅读理解；
2. 不要用题号、卷名、"数学题"这种不区分知识点的词；
3. 同一批题尽量复用已有标签（同义词统一成一个说法）；
4. 信息不足就按最可能的考点给一个标签，不要留空、不要编造题型。
只输出严格 JSON，不要解释、不要 markdown 围栏；**键必须用用户给的 qN 短键**：
{"tags":{"q1":["标签1","标签2"],"q2":["标签1"]}}''';

/// 归纳任务的 user：每题一行，带短键 + 原 id 便于回填。
String knowledgeTagUser(List<KnowledgeTagItem> items) {
  final StringBuffer buffer = StringBuffer('待归纳的题（共 ${items.length} 道）：\n');
  for (int i = 0; i < items.length; i++) {
    final KnowledgeTagItem item = items[i];
    buffer
      ..write(
        'q${i + 1} | 第 ${item.label} 题 | ${item.workbookTitle} | '
        '${_kindLabel(item.kind)} | id=${item.id}',
      )
      ..write('\n题干：${item.clippedStem.isEmpty ? '（无文本，按题号与卷名判断）' : item.clippedStem}')
      ..writeln();
  }
  buffer.writeln('请按 system 要求只输出 JSON，键用 q1、q2…。');
  return buffer.toString();
}

String _kindLabel(String kind) => switch (kind) {
  'choice' => '选择题',
  'judge' => '判断题',
  'blank' => '填空题',
  'essay' => '解答题',
  _ => '题目',
};

/// 解析归纳结果：`{"tags":{"q1":["a","b"]}}`。
///
/// 宽容处理：
/// - markdown 围栏 / 前后解释；
/// - `tags` 为对象、为 `[{id,tags}]` 列表、或顶层直接键值；
/// - 顶层包一层 `results` / `data` / `items` / `list`；
/// - 整个回复就是一个 JSON 数组（`[{"id":..,"tags":[..]}]`）；
/// - 值可以是数组，也可以是逗号分隔的字符串。
///
/// 任何"一个合法标签都没有"的情况返回 null —— 上层提示重试，不写半份标签。
Map<String, List<String>>? parseKnowledgeTagResponse(String raw) {
  // 模型可能整段就是一个数组。**必须先判数组**：对象扫描会命中数组里的
  // 第一个对象（`[{"id":"a"}]` → `{"id":"a"}`），那样就把后面的条目全丢了
  // （2026-10-26 改 extractJsonObject 为配对扫描时踩到的回归）。
  final String trimmed = stripCodeFence(raw).trimLeft();
  if (trimmed.startsWith('[')) {
    final List<Object?>? array = extractJsonArray(raw);
    if (array != null) {
      return _fromPairs(<String, Object?>{
        for (int i = 0; i < array.length; i++) 'q${i + 1}': array[i],
      });
    }
  }
  final Map<String, Object?>? json = extractJsonObject(raw);
  if (json == null) {
    // 最后一招：模型完全没按 JSON，写成"q1：极限、函数"这种行。
    return parseKnowledgeTagLines(raw);
  }
  final Map<String, List<String>> out = <String, List<String>>{};
  void put(String id, Object? value) {
    if (id.isEmpty) {
      return;
    }
    final List<String> normalized = _normalize(value);
    if (normalized.isNotEmpty) {
      out[id] = normalized;
    }
  }

  // 兼容常见的包装键。
  for (final String wrapper in <String>[
    'tags',
    'results',
    'data',
    'items',
    'list',
    'knowledge_tags',
    'knowledge_points',
  ]) {
    final Object? value = json[wrapper];
    if (value == null) {
      continue;
    }
    if (value is Map) {
      value.forEach((Object? key, Object? item) {
        if (key is String) {
          put(key, _tagsOf(item) ?? item);
        }
      });
    } else if (value is List) {
      _fromList(value, put);
    }
    if (out.isNotEmpty) {
      return out;
    }
  }
  // 顶层直接 id → 标签（模型偶尔省掉 tags 包装）。
  json.forEach((String key, Object? value) {
    final Object? tags = _tagsOf(value);
    if (tags != null) {
      put(key, tags);
    } else if (value is String || value is List) {
      put(key, value);
    }
  });
  return out.isEmpty ? null : out;
}

void _fromList(List<Object?> list, void Function(String, Object?) put) {
  for (int i = 0; i < list.length; i++) {
    final Object? item = list[i];
    if (item is Map) {
      final Object? id =
          item['id'] ??
          item['favorite_id'] ??
          item['question_id'] ??
          item['key'] ??
          item['label'] ??
          item['ordinal'];
      final Object? tags =
          item['tags'] ?? item['knowledge_tags'] ?? item['knowledge_points'];
      if (id != null && tags != null) {
        put('$id', tags);
      }
    } else if (item is String) {
      put('q${i + 1}', item);
    }
  }
}

Map<String, List<String>> _fromPairs(Map<String, Object?> pairs) {
  final Map<String, List<String>> out = <String, List<String>>{};
  pairs.forEach((String key, Object? value) {
    // 数组形态 `[{id,tags}]`：键是位置，真正的 id 在元素里；按 id 收，
    // 否则后续映射会把 q1/q2 当成题号（碰巧也能对上，但不如 id 直接）。
    if (value is Map) {
      final Object? id =
          value['id'] ??
          value['favorite_id'] ??
          value['question_id'] ??
          value['key'];
      final Object tags = _tagsOf(value) ?? value;
      final List<String> normalized = _normalize(tags);
      if (normalized.isNotEmpty) {
        out[id?.toString() ?? key] = normalized;
      }
      return;
    }
    final Object? tags = _tagsOf(value) ?? value;
    final List<String> normalized = _normalize(tags);
    if (normalized.isNotEmpty) {
      out[key] = normalized;
    }
  });
  return out;
}

/// 从"对象元素"里取 tags（`{"q1":["a"]}` 的值本身就是列表时返回 null）。
Object? _tagsOf(Object? value) {
  if (value is Map) {
    return value['tags'] ??
        value['knowledge_tags'] ??
        value['knowledge_points'] ??
        value['labels'];
  }
  return null;
}

List<String> _normalize(Object? raw) {
  final List<String> chunks = <String>[];
  if (raw is List) {
    for (final Object? item in raw) {
      if (item is String) {
        chunks.add(item);
      } else if (item is Map && item['name'] is String) {
        chunks.add(item['name']! as String);
      }
    }
  } else if (raw is String) {
    chunks.addAll(raw.split(RegExp(r'[,，、;；]')));
  }
  // 与手动标签同一套规则：去空白、去重、单个 ≤20 字、最多 5 个。
  return KnowledgeTags.parse(chunks.join(','));
}

/// 非 JSON 的兜底：按行读 `q1：极限、函数` / `第 3 题: 导数` / `3. 概率`。
///
/// 只接受"键 + 分隔符 + 至少一个合法标签"的行；一行都没有就返回 null。
/// 这条兜底的意义：很多中转/小模型 JSON 能力差，但分行列出知识点很稳定，
/// 与其报"没有可用标签"，不如把能读的读出来（后面还有用户确认）。
Map<String, List<String>>? parseKnowledgeTagLines(String raw) {
  final Map<String, List<String>> out = <String, List<String>>{};
  final RegExp linePattern = RegExp(
    r'^\s*(?:[-*•]\s*)?(q\d+|第?\s*\d+\s*[题.．]?)\s*[:：.\-、]\s*(.+)$',
    caseSensitive: false,
  );
  for (final String line in raw.split('\n')) {
    final RegExpMatch? match = linePattern.firstMatch(line);
    if (match == null) {
      continue;
    }
    final List<String> tags = _normalize(match.group(2));
    if (tags.isEmpty) {
      continue;
    }
    out[match.group(1)!.replaceAll(RegExp(r'[\s题.．第]'), '')] = tags;
  }
  if (out.isEmpty) {
    return null;
  }
  return out;
}

/// 把模型返回的键映射回题目 id。
///
/// 支持：短键 `qN` / 原 id / `第 3 题` / 纯数字题号。
Map<String, List<String>> resolveKnowledgeTagKeys(
  Map<String, List<String>> parsed,
  List<KnowledgeTagItem> items,
) {
  final Map<String, List<String>> out = <String, List<String>>{};
  for (final MapEntry<String, List<String>> entry in parsed.entries) {
    final String? id = _matchKey(entry.key, items);
    if (id != null) {
      final List<String> merged = <String>[
        ...?out[id],
        ...entry.value,
      ];
      out[id] = KnowledgeTags.parse(merged.join(','));
      continue;
    }
    // 反向结构：`{"极限":["q1","q2"]}` —— 键是标签，值是题号。
    // 只接受"值全部能对上题"且键像标签（1–20 字）的情况，避免把
    // 模型的解释性字段当成标签。
    final String key = entry.key.trim();
    if (key.isEmpty || key.length > 20) {
      continue;
    }
    final List<String> refs = entry.value
        .map((String value) => _matchKey(value, items))
        .whereType<String>()
        .toList(growable: false);
    if (refs.isEmpty) {
      continue;
    }
    final List<String> tags = KnowledgeTags.parse(key);
    if (tags.isEmpty) {
      continue;
    }
    for (final String ref in refs) {
      out[ref] = KnowledgeTags.parse(<String>[...?out[ref], ...tags].join(','));
    }
  }
  return out;
}

String? _matchKey(String rawKey, List<KnowledgeTagItem> items) {
  final String key = rawKey.trim();
  if (key.isEmpty) {
    return null;
  }
  // 1) 原 id。
  for (final KnowledgeTagItem item in items) {
    if (item.id == key) {
      return item.id;
    }
  }
  // 2) 短键 qN。
  final RegExpMatch? short = RegExp(r'^q(\d+)$').firstMatch(key.toLowerCase());
  if (short != null) {
    final int index = int.tryParse(short.group(1)!) ?? 0;
    if (index >= 1 && index <= items.length) {
      return items[index - 1].id;
    }
  }
  // 3) 「第 3 题」/「3.」/「3」→ 与题号标签的纯数字部分比。
  final String digits = _digitsOf(key);
  if (digits.isNotEmpty) {
    for (final KnowledgeTagItem item in items) {
      if (_digitsOf(item.label) == digits) {
        return item.id;
      }
      if (item.ordinal > 0 && '${item.ordinal}' == digits) {
        return item.id;
      }
    }
  }
  return null;
}

String _digitsOf(String raw) {
  final RegExpMatch? match = RegExp(r'\d+').firstMatch(raw);
  return match?.group(0) ?? '';
}
