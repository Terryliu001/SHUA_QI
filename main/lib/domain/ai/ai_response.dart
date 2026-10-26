/// AI 回复的解析（纯 Dart，可单测）。
///
/// 模型很爱加三件事：```json 围栏、JSON 前后的解释、以及把 `steps` 写成数组。
/// 这里做**宽容解析**：能救就救，救不出来返回 null，让上层显示"格式异常"
/// 而不是把半截 JSON 当答案落库。
library;

import 'dart:convert';

import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/model/grading.dart';

/// 去掉 markdown 代码围栏（```json ... ``` / ``` ... ```）。
String stripCodeFence(String raw) {
  String text = raw.trim();
  if (!text.startsWith('```')) {
    return text;
  }
  final int firstNewline = text.indexOf('\n');
  if (firstNewline < 0) {
    return text;
  }
  text = text.substring(firstNewline + 1);
  final int closing = text.lastIndexOf('```');
  if (closing >= 0) {
    text = text.substring(0, closing);
  }
  return text.trim();
}

/// 从任意文本里抠出**第一个完整的** JSON 对象。失败返回 null。
///
/// ## 为什么不能取"第一个 `{` 到最后一个 `}`"（2026-10-26 修）
/// 旧实现用 `indexOf('{')` + `lastIndexOf('}')`。模型很爱这么回：
/// ```
/// 好的，这是结论：{"verdict":"correct","reason":"…"}
/// 另外补充一下：{"note":"…"}
/// ```
/// 截出来的是 `{"verdict":…} 另外补充… {"note":…}` —— 不是合法 JSON，
/// 于是解析失败，界面上冒出一句"AI 判题结果格式异常"。
///
/// 现在改成**括号配对扫描**：从第一个 `{` 开始数括号（跳过字符串里的括号），
/// 配平的那一刻就是对象结束。
Map<String, Object?>? extractJsonObject(String raw) {
  final String text = stripCodeFence(raw);
  final int start = text.indexOf('{');
  if (start < 0) {
    return null;
  }
  final int? end = _matchingBrace(text, start, '{', '}');
  if (end == null) {
    return null;
  }
  try {
    final Object? decoded = jsonDecode(text.substring(start, end + 1));
    if (decoded is Map) {
      return decoded.cast<String, Object?>();
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// 从 [start] 处的括号开始做**配对扫描**，返回配平位置（不含）。
///
/// 字符串字面量里的括号不算：模型写 `reason: "答案是 {x}"` 时不能被带偏。
int? _matchingBrace(String text, int start, String open, String close) {
  int depth = 0;
  bool inString = false;
  bool escaped = false;
  for (int i = start; i < text.length; i += 1) {
    final String ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
      continue;
    }
    if (ch == open) {
      depth += 1;
    } else if (ch == close) {
      depth -= 1;
      if (depth == 0) {
        return i;
      }
    }
  }
  return null;
}

/// 从任意文本里抠出第一个 JSON **数组**。失败返回 null。
///
/// 有些模型（尤其小模型/中转）会把批量结果直接写成 `[{...},{...}]`，
/// 而不是 system 要求的对象。解析层先接住，再决定怎么解释。
List<Object?>? extractJsonArray(String raw) {
  final String text = stripCodeFence(raw);
  final int start = text.indexOf('[');
  if (start < 0) {
    return null;
  }
  final int? end = _matchingBrace(text, start, '[', ']');
  if (end == null) {
    return null;
  }
  try {
    final Object? decoded = jsonDecode(text.substring(start, end + 1));
    if (decoded is List) {
      return decoded;
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// 解析判题结果。
///
/// 两条路：
/// 1. **JSON**（首选）：`{"verdict":"correct","reason":"…"}`；
/// 2. **纯文字兜底**（2026-10-26 加）：模型有时不听话，直接写
///    "这道题不对，答案应该是 x"。这时候与其弹"格式异常"让用户重试，
///    不如把结论接住，并在界面上标「按文字判定 · 请复核」。
///
/// 兜底只在**能明确读出判定词**时启用；读不出来仍然返回 null（上层不落判题）。
AiGrade? parseAiGrade(String raw) {
  final Map<String, Object?>? json = extractJsonObject(raw);
  if (json != null) {
    final AnswerVerdict? verdict =
        _verdictOf(json['verdict'] ?? json['result'] ?? json['conclusion']);
    if (verdict != null) {
      final String reason = _stringOf(
        json['reason'] ?? json['note'] ?? json['explanation'] ?? json['detail'],
      ).trim();
      final double confidence = _doubleOf(json['confidence']);
      return AiGrade(
        verdict: verdict,
        reason: reason.isEmpty ? 'AI 没有给出理由' : reason,
        confidence: confidence,
      );
    }
  }
  // 纯文字兜底。
  final String text = stripLightMarkdown(stripCodeFence(raw)).trim();
  if (text.isEmpty) {
    return null;
  }
  final AnswerVerdict? verdict = _verdictFromText(text);
  if (verdict == null) {
    return null;
  }
  return AiGrade(
    verdict: verdict,
    reason: _capReason(text),
    confidence: 0,
    fromText: true,
  );
}

/// 从纯文字里读判定结论。读不出返回 null。
///
/// 顺序很重要：先看否定词（"不对"），再看拿不准，最后才看肯定词——
/// "答案不对，应该是 B" 里同时有"对"和"不对"，只看肯定词会判反。
AnswerVerdict? _verdictFromText(String text) {
  final String lower = text.toLowerCase();
  const List<String> wrong = <String>[
    '不对',
    '不正确',
    '错误',
    '错了',
    '答错',
    'wrong',
    'incorrect',
  ];
  const List<String> pending = <String>[
    '拿不准',
    '不确定',
    '无法判断',
    '不能确定',
    'unclear',
    'uncertain',
  ];
  const List<String> correct = <String>[
    '正确',
    '对了',
    '答对',
    '是对的',
    'correct',
    'right',
  ];
  if (wrong.any(lower.contains)) {
    return AnswerVerdict.wrong;
  }
  if (pending.any(lower.contains)) {
    return AnswerVerdict.pending;
  }
  if (correct.any(lower.contains)) {
    return AnswerVerdict.correct;
  }
  return null;
}

/// 理由最长 600 字：超了截断（AI 有时能写一整屏）。
String _capReason(String text) {
  const int limit = 600;
  final String flat = text.trim();
  if (flat.length <= limit) {
    return flat;
  }
  return '${flat.substring(0, limit)}…';
}

/// 解析"先做一遍"的 JSON。
///
/// 解析不出 JSON 时不返回 null：把原文当作解析，保留 `answer` 为空，
/// 面板仍能展示模型写了什么，只是不落答案库。
AiSolution? parseAiSolution(String raw) {
  final Map<String, Object?>? json = extractJsonObject(raw);
  if (json == null) {
    final String text = stripCodeFence(raw).trim();
    if (text.isEmpty) {
      return null;
    }
    return AiSolution(answer: _answerLineOf(text), explanation: text, raw: raw);
  }
  final String answer = _stringOf(
    json['answer'] ?? json['final_answer'] ?? json['result'],
  ).trim();
  final String explanation = _explanationOf(
    json['explanation'] ?? json['analysis'] ?? json['steps'],
  );
  if (answer.isEmpty && explanation.isEmpty) {
    return null;
  }
  return AiSolution(
    answer: answer,
    explanation: explanation.isEmpty ? answer : explanation,
    confidence: _doubleOf(json['confidence']),
    raw: raw,
  );
}

/// 从纯文本里找一行"答案：…"。找不到返回空。
String _answerLineOf(String text) {
  final RegExp pattern = RegExp(
    r'(?:最终)?答案\s*[:：]\s*([^\n]+)',
    caseSensitive: false,
  );
  final RegExpMatch? match = pattern.firstMatch(text);
  return match?.group(1)?.trim() ?? '';
}

String _explanationOf(Object? raw) {
  if (raw == null) {
    return '';
  }
  if (raw is String) {
    return raw.trim();
  }
  if (raw is List) {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < raw.length; i++) {
      final String item = _stringOf(raw[i]).trim();
      if (item.isEmpty) {
        continue;
      }
      if (buffer.isNotEmpty) {
        buffer.writeln();
      }
      buffer.write('${i + 1}. $item');
    }
    return buffer.toString();
  }
  return _stringOf(raw).trim();
}

AnswerVerdict? _verdictOf(Object? raw) {
  final String value = _stringOf(raw).trim().toLowerCase();
  switch (value) {
    case 'correct':
    case 'right':
    case 'true':
    case '正确':
    case '对':
      return AnswerVerdict.correct;
    case 'wrong':
    case 'incorrect':
    case 'false':
    case '错误':
    case '错':
      return AnswerVerdict.wrong;
    case 'pending':
    case 'unclear':
    case 'uncertain':
    case '待判':
    case '不确定':
      return AnswerVerdict.pending;
    default:
      return null;
  }
}

String _stringOf(Object? raw) {
  if (raw == null) {
    return '';
  }
  if (raw is String) {
    return raw;
  }
  if (raw is num || raw is bool) {
    return '$raw';
  }
  return '';
}

double _doubleOf(Object? raw) {
  double value = 0;
  if (raw is num) {
    value = raw.toDouble();
  } else if (raw is String) {
    value = double.tryParse(raw) ?? 0;
  }
  return value.clamp(0, 1).toDouble();
}

/// 去掉模型爱加的轻量 markdown 记号，保留公式定界符与换行。
///
/// 不引 `flutter_markdown`：这一轮只需要"读得顺"，不需要完整 markdown 排版。
String stripLightMarkdown(String raw) {
  String text = stripCodeFence(raw);
  // 行首标题 # / ## / ###
  text = text.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
  // 粗体 / 斜体 / 行内代码
  text = text.replaceAll('**', '');
  text = text.replaceAll('__', '');
  text = text.replaceAllMapped(
    RegExp(r'`([^`\n]+)`'),
    (Match match) => match.group(1) ?? '',
  );
  // 三个以上连续空行压成两个
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}
