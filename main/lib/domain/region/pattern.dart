/// 题号识别（纯 Dart，可单测）。
///
/// 输入是**一行的文本**（`TextLine.text`，已聚行拼接），输出是"这行以什么题号开头"。
///
/// 两条纪律：
/// 1. **顺序匹配、命中即停**：`1.` 与 `（1）` 是两种不同层级，不能都试一遍取最长的。
/// 2. **宁可漏、不可错**：误判一个伪题号（`1.5 分`、`图 3-1`），会在卷面上切出一个
///    错位的框；漏一个题号只是"少切一道"，用户还能手动补（T3.4）。
library;

/// 题号样式。
enum MarkKind {
  /// `1.` `12、` `3．`
  arabic,

  /// `(3)` `（3）`
  parenArabic,

  /// `①`–`⑳`
  circled,

  /// `第 5 题`
  thQuestion,

  /// `【例 7】` `[习题 3]`
  example,

  /// `一、` `二．`
  cnNumeral,

  /// `Ⅰ.` `Ⅲ、`
  roman,
}

/// 一个被识别出来的题号。
class QuestionMark {
  const QuestionMark({
    required this.label,
    required this.kind,
    required this.rest,
    this.number,
  });

  /// 题号原文（含分隔符，已 trim），用于展示与入库 `question.label`。
  final String label;

  final MarkKind kind;

  /// 题号之后的正文（已 trim，可能为空）。
  final String rest;

  /// 阿拉伯数字；中文数字/圈号也尽量折算成整数，折不出来给 null。
  final int? number;

  /// 结构上更像"大题"的题号样式（中文数字 / 罗马数字 / 例）。
  ///
  /// 这只是**倾向**，最终层级由 [leveling] 结合字号决定。
  bool get prefersMajor =>
      kind == MarkKind.cnNumeral ||
      kind == MarkKind.roman ||
      kind == MarkKind.example;
}

/// 六级题号正则。顺序即优先级（规格 T3.2 原文）。
final List<_MarkPattern> _patterns = <_MarkPattern>[
  _MarkPattern(
    RegExp(r'^(\d{1,3})\s*[.、．]\s*'),
    MarkKind.arabic,
    (Match match) => int.tryParse(match.group(1)!),
  ),
  _MarkPattern(
    RegExp(r'^[（(]\s*(\d{1,2})\s*[）)]\s*'),
    MarkKind.parenArabic,
    (Match match) => int.tryParse(match.group(1)!),
  ),
  _MarkPattern(RegExp(r'^([①-⑳])\s*'), MarkKind.circled, (Match match) {
    final int code = match.group(1)!.runes.first;
    return code - 0x2460 + 1;
  }),
  _MarkPattern(
    RegExp(r'^第\s*(\d{1,3})\s*题\s*[.、．:：]?\s*'),
    MarkKind.thQuestion,
    (Match match) => int.tryParse(match.group(1)!),
  ),
  _MarkPattern(
    RegExp(r'^[【\[]\s*(?:例|习题|练习)?\s*(\d{1,3})\s*[】\]]\s*'),
    MarkKind.example,
    (Match match) => int.tryParse(match.group(1)!),
  ),
  _MarkPattern(
    RegExp(r'^([一二三四五六七八九十]{1,3})\s*[、.．]\s*'),
    MarkKind.cnNumeral,
    (Match match) => cnNumeralToInt(match.group(1)!),
  ),
  // `三(14分) 求函数…`：分数紧跟中文序号、**没有顿号**。真卷（北邮 2025 期中）
  // 的四道计算题全是这种写法，漏掉它就等于整卷后四题全丢。
  _MarkPattern(
    RegExp(r'^([一二三四五六七八九十]{1,3})\s*[（(]\s*\d+\s*分\s*[）)]\s*'),
    MarkKind.cnNumeral,
    (Match match) => cnNumeralToInt(match.group(1)!),
  ),
  _MarkPattern(RegExp(r'^([ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ]{1,4})\s*[、.．]\s*'), MarkKind.roman, (
    Match match,
  ) {
    final String token = match.group(1)!;
    return token.isEmpty ? null : romanToInt(token);
  }),
];

/// 从行文本里抽题号。抽不到返回 null。
///
/// 注意：首尾空白先清掉再匹配，否则 `TextLine` 里拼接产生的空格会让 `^` 失配。
QuestionMark? matchQuestionMark(String rawText) {
  final String text = rawText.trimLeft();
  if (text.isEmpty) {
    return null;
  }
  for (final _MarkPattern pattern in _patterns) {
    final Match? match = pattern.regexp.matchAsPrefix(text);
    if (match == null) {
      continue;
    }
    final String rest = text.substring(match.end).trim();
    if (pseudoReason(rest, pattern.kind) != null) {
      return null;
    }
    String label = match.group(0)!.trim();
    if (pattern.kind == MarkKind.cnNumeral &&
        (label.contains('（') || label.contains('('))) {
      // 只留序号 + 顿号：`五(8分)` → `五、`，角标不该挤进分值。
      final RegExpMatch? head = RegExp(r'^([一二三四五六七八九十]{1,3})')
          .firstMatch(label);
      if (head != null) {
        label = '${head.group(1)}、';
      }
    }
    return QuestionMark(
      label: label,
      kind: pattern.kind,
      rest: rest,
      number: pattern.numberOf(match),
    );
  }
  return null;
}

/// 伪题号的排除。命中返回原因（便于单测断言），不是伪题号返回 null。
String? pseudoReason(String rest, MarkKind kind) {
  if (rest.isEmpty) {
    // 单独一行的纯数字 / 纯题号：多半是页码、题表编号或排版残留。
    return 'rest-empty';
  }
  final String head = rest.substring(0, 1);
  const Set<String> citations = <String>{'图', '表', '页', '式', '章', '节', '注'};
  if (citations.contains(head)) {
    return 'citation';
  }
  // `1.5 分` / `2.4 已知…`：数字后紧跟数字是小数，不是题号。
  if (RegExp(r'^\d').hasMatch(rest)) {
    return 'decimal';
  }
  // 括号题号后面直接跟"分"字：`（3 分）` 这种分值标注。
  if (kind == MarkKind.parenArabic && rest.startsWith('分')) {
    return 'score';
  }
  return null;
}

/// 题型粗判（规格 T3.2 第 4 步）。只看题干文本，不做语义理解。
String classifyKind(String stem) {
  // A. xxx B. xxx（至少两个选项标记才当选择题，避免把"图 A. 所示"算进去）
  final int optionHits = RegExp(r'(?:^|\s)[A-D]\s*[.、．]')
      .allMatches(stem)
      .length;
  if (optionHits >= 2) {
    return 'choice';
  }
  // 规格口径：句中留一对空括号 `（  ）`（无论全角半角、里面几个空格）算判断题。
  if (stem.contains('判断') ||
      _judgeFillPattern.hasMatch(stem) ||
      _blankHolePattern.hasMatch(stem)) {
    return 'judge';
  }
  if (stem.contains('填空') || stem.contains('____') || stem.contains('＿＿')) {
    return 'blank';
  }
  return 'essay';
}

/// `填"对"或"错"` 这类判断题的作答提示（真卷里很常见，但没有"判断"二字）。
final RegExp _judgeFillPattern = RegExp(r'对[”"』]?\s*或\s*[“"『]?错');
final RegExp _blankHolePattern = RegExp(r'（\s*）|\(\s*\)');

/// 从**大题标题**反推题型（`一、填空题（共 30 分）` → `blank`）。
///
/// 为什么需要：小题自己往往看不出题型——填空题干里既没有"填空"二字也没有下划线，
/// 只有上一级标题知道整节是什么。返回 null 表示标题没给线索。
String? kindFromHeading(String heading) {
  if (heading.contains('选择')) {
    return 'choice';
  }
  if (heading.contains('填空')) {
    return 'blank';
  }
  if (heading.contains('判断')) {
    return 'judge';
  }
  if (heading.contains('计算') ||
      heading.contains('证明') ||
      heading.contains('解答') ||
      heading.contains('应用')) {
    return 'essay';
  }
  return null;
}

/// 中文数字 → 整数（支持 1–99：`三` `十` `十五` `二十`）。
int? cnNumeralToInt(String token) {
  const Map<String, int> digits = <String, int>{
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  if (token.isEmpty) {
    return null;
  }
  if (!token.contains('十')) {
    if (token.length == 1) {
      return digits[token];
    }
    // 极少见的 `二三` 之类，不猜。
    return null;
  }
  final int tenIndex = token.indexOf('十');
  final String tensPart = token.substring(0, tenIndex);
  final String onesPart = token.substring(tenIndex + 1);
  final int tens = tensPart.isEmpty ? 1 : (digits[tensPart] ?? 0);
  final int ones = onesPart.isEmpty ? 0 : (digits[onesPart] ?? 0);
  if (tens == 0) {
    return null;
  }
  if (onesPart.isNotEmpty && ones == 0) {
    return null;
  }
  return tens * 10 + ones;
}

/// 罗马数字 → 整数（只支持 1–39，试卷题号足够）。
int? romanToInt(String token) {
  const Map<String, int> values = <String, int>{
    'Ⅰ': 1,
    'Ⅱ': 2,
    'Ⅲ': 3,
    'Ⅳ': 4,
    'Ⅴ': 5,
    'Ⅵ': 6,
    'Ⅶ': 7,
    'Ⅷ': 8,
    'Ⅸ': 9,
    'Ⅹ': 10,
    'Ⅺ': 11,
    'Ⅻ': 12,
  };
  if (token.isEmpty) {
    return null;
  }
  if (token.length == 1) {
    return values[token];
  }
  // 组合形式（ⅩⅢ 这类单字符之外的连写）不猜，返回 null。
  return null;
}

class _MarkPattern {
  const _MarkPattern(this.regexp, this.kind, this.numberOf);

  final RegExp regexp;
  final MarkKind kind;
  final int? Function(Match match) numberOf;
}
