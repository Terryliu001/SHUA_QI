/// 一份卷子的答案索引（纯 Dart）。
///
/// 当前来源只有 PDF 文本层的「参考答案」区；后续 OCR/AI 来源也走同一形状，
/// 用 [source] 标明，面板按来源显示徽标（PDF / OCR / 手工 / AI）。
library;

/// 一条答案。
class AnswerNote {
  const AnswerNote({
    required this.label,
    required this.text,
    this.source = 'pdf_text',
    this.pageIndex,
    this.ordinal,
  });

  factory AnswerNote.fromJson(Map<String, Object?> json) => AnswerNote(
    label: (json['label'] as String?) ?? '',
    text: (json['text'] as String?) ?? '',
    source: (json['source'] as String?) ?? 'pdf_text',
    pageIndex: (json['page'] as num?)?.toInt(),
    ordinal: (json['ordinal'] as num?)?.toInt(),
  );

  final String label;
  final String text;

  /// `pdf_text` / `inline` / `ocr` / `manual` / `ai`。
  final String source;

  final int? pageIndex;

  /// 题在全卷的 ordinal。**优先用它匹配**：同一份卷子可能有多个 `1.`
  /// （填空题 1. 与选择题 1.），只按 label 会串答案。
  final int? ordinal;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'text': text,
    'source': source,
    'page': pageIndex,
    'ordinal': ordinal,
  };
}

/// label / ordinal → 答案。
class AnswerSet {
  const AnswerSet(this.byLabel, {this.byOrdinal = const <int, AnswerNote>{}});

  static const AnswerSet empty = AnswerSet(<String, AnswerNote>{});

  final Map<String, AnswerNote> byLabel;

  /// 题内解析按 ordinal 精确挂；有它时优先于 label。
  final Map<int, AnswerNote> byOrdinal;

  bool get isEmpty => byLabel.isEmpty && byOrdinal.isEmpty;

  AnswerNote? forLabel(String? label) {
    if (label == null) {
      return null;
    }
    return byLabel[answerKeyOf(label)];
  }

  /// 面板选中题时用这个：ordinal 精确优先，label 兜底。
  AnswerNote? forQuestion({required int ordinal, String? label}) {
    return byOrdinal[ordinal] ?? forLabel(label);
  }

  /// 用 [extra] **补缺**（已有的答案不覆盖）。
  ///
  /// 用途：`answers.v1.json` 是 PDF 自动抽取（权威、可重抽），
  /// `answers_ai.v1.json` 是 AI 补的（用户产物）。合并时先放 PDF，
  /// 再用 AI 补没有的题；PDF 一旦有答案，AI 不该把它顶掉。
  AnswerSet mergeMissing(AnswerSet extra) {
    if (extra.isEmpty) {
      return this;
    }
    final Map<String, AnswerNote> labels = Map<String, AnswerNote>.of(byLabel);
    final Map<int, AnswerNote> ordinals = Map<int, AnswerNote>.of(byOrdinal);
    for (final MapEntry<int, AnswerNote> entry in extra.byOrdinal.entries) {
      ordinals.putIfAbsent(entry.key, () => entry.value);
    }
    for (final MapEntry<String, AnswerNote> entry in extra.byLabel.entries) {
      labels.putIfAbsent(entry.key, () => entry.value);
    }
    return AnswerSet(labels, byOrdinal: ordinals);
  }

  /// 写入/替换一条答案（AI 补答案用）。label 与 ordinal 两个索引都写。
  AnswerSet withNote(AnswerNote note) {
    final Map<String, AnswerNote> labels = Map<String, AnswerNote>.of(byLabel);
    final Map<int, AnswerNote> ordinals = Map<int, AnswerNote>.of(byOrdinal);
    if (note.ordinal != null) {
      ordinals[note.ordinal!] = note;
    }
    final String key = answerKeyOf(note.label);
    if (key.isNotEmpty) {
      labels[key] = note;
    }
    return AnswerSet(labels, byOrdinal: ordinals);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'answers': <Map<String, Object?>>[
      for (final AnswerNote note in <AnswerNote>{
        ...byLabel.values,
        ...byOrdinal.values,
      })
        note.toJson(),
    ],
  };

  factory AnswerSet.fromJson(Map<String, Object?>? json) {
    if (json == null) {
      return empty;
    }
    final Object? raw = json['answers'];
    if (raw is! List) {
      return empty;
    }
    final Map<String, AnswerNote> byLabel = <String, AnswerNote>{};
    final Map<int, AnswerNote> byOrdinal = <int, AnswerNote>{};
    for (final Object? item in raw) {
      if (item is! Map) {
        continue;
      }
      final AnswerNote note = AnswerNote.fromJson(item.cast<String, Object?>());
      if (note.text.trim().isEmpty) {
        continue;
      }
      if (note.ordinal != null) {
        byOrdinal[note.ordinal!] = note;
      } else {
        final String key = answerKeyOf(note.label);
        if (key.isNotEmpty) {
          byLabel[key] = note;
        }
      }
    }
    return AnswerSet(byLabel, byOrdinal: byOrdinal);
  }
}

/// 题号归一：去空白、去尾部 `。.、:：`，让 "1." 与 "1" 对上。
String answerKeyOf(String label) => label
    .trim()
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll(RegExp(r'[.。、:：]+$'), '');
