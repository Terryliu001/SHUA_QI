/// 答题卡纸张配置 —— 纯 Dart（尺寸/方向/张数/纸样式）。
///
/// 用户口径（2026-10-24 第 1 条）：默认保持现在的样子，但要能自定义：
/// - 尺寸预设：默认（5:3 横）/ A4 / B5，各支持横竖；
/// - 张数 1–4：证明过程长的题要能写多张，且**按顺序统一算作这一题的作答**；
/// - 纸样式：横线（默认）/ 虚线 / 点阵 / 方格 / 空白。
///
/// 尺寸单位一律「pt」，与 PDF 页、SIF 编码同一套坐标口径（1pt = 1/72 inch）。
library;

enum AnswerPaperSize {
  /// 现在用的虚拟画布（1000×600，5:3）。
  compact,
  a4,
  b5;

  static AnswerPaperSize decode(String? raw) {
    for (final AnswerPaperSize value in values) {
      if (value.name == raw) {
        return value;
      }
    }
    return AnswerPaperSize.compact;
  }

  String get label => switch (this) {
    AnswerPaperSize.compact => '默认',
    AnswerPaperSize.a4 => 'A4',
    AnswerPaperSize.b5 => 'B5',
  };

  /// 竖向的宽高（pt）。A4 = 210×297mm，B5 = 176×250mm。
  ({double width, double height}) get portrait => switch (this) {
    AnswerPaperSize.compact => (width: 600, height: 1000),
    AnswerPaperSize.a4 => (width: 595, height: 842),
    AnswerPaperSize.b5 => (width: 499, height: 709),
  };
}

enum AnswerPaperOrientation {
  landscape,
  portrait;

  static AnswerPaperOrientation decode(String? raw) =>
      raw == portrait.name ? portrait : landscape;

  String get label => this == portrait ? '竖向' : '横向';
}

enum AnswerPaperRule {
  lines,
  dashed,
  dots,
  grid,
  blank;

  static AnswerPaperRule decode(String? raw) {
    for (final AnswerPaperRule value in values) {
      if (value.name == raw) {
        return value;
      }
    }
    return AnswerPaperRule.lines;
  }

  String get label => switch (this) {
    AnswerPaperRule.lines => '横线',
    AnswerPaperRule.dashed => '虚线',
    AnswerPaperRule.dots => '点阵',
    AnswerPaperRule.grid => '方格',
    AnswerPaperRule.blank => '空白',
  };
}

/// 一份纸张配置。
class AnswerPaper {
  const AnswerPaper({
    this.size = AnswerPaperSize.compact,
    this.orientation = AnswerPaperOrientation.landscape,
    this.pages = 1,
    this.rule = AnswerPaperRule.lines,
  });

  factory AnswerPaper.fromJson(Map<String, Object?>? json) {
    if (json == null) {
      return defaults;
    }
    return AnswerPaper(
      size: AnswerPaperSize.decode(json['size'] as String?),
      orientation: AnswerPaperOrientation.decode(
        json['orientation'] as String?,
      ),
      pages: ((json['pages'] as num?)?.toInt() ?? 1).clamp(1, maxPages),
      rule: AnswerPaperRule.decode(json['rule'] as String?),
    );
  }

  static const AnswerPaper defaults = AnswerPaper();

  /// 一道题最多几张。
  ///
  /// 2026-10-24 第二轮：用户要求"上限 9 张（不显示）"——加到第 9 张为止，
  /// 界面上不写"最多 9 张"，只让「＋」在到顶后变灰。
  static const int maxPages = 9;

  final AnswerPaperSize size;
  final AnswerPaperOrientation orientation;

  /// 张数（1–4）。
  final int pages;

  final AnswerPaperRule rule;

  /// 画布宽（pt）。
  double get widthPt {
    final ({double width, double height}) base = size.portrait;
    return orientation == AnswerPaperOrientation.portrait
        ? base.width
        : base.height;
  }

  /// 画布高（pt）。
  double get heightPt {
    final ({double width, double height}) base = size.portrait;
    return orientation == AnswerPaperOrientation.portrait
        ? base.height
        : base.width;
  }

  double get aspect => widthPt / heightPt;

  String get summary =>
      '${size.label} · ${orientation.label} · $pages 张 · ${rule.label}';

  AnswerPaper copyWith({
    AnswerPaperSize? size,
    AnswerPaperOrientation? orientation,
    int? pages,
    AnswerPaperRule? rule,
  }) => AnswerPaper(
    size: size ?? this.size,
    orientation: orientation ?? this.orientation,
    pages: (pages ?? this.pages).clamp(1, maxPages),
    rule: rule ?? this.rule,
  );

  /// 换尺寸/方向时保留张数与纸样式。
  bool sameLayout(AnswerPaper other) =>
      size == other.size && orientation == other.orientation;

  Map<String, Object?> toJson() => <String, Object?>{
    'size': size.name,
    'orientation': orientation.name,
    'pages': pages,
    'rule': rule.name,
  };

  @override
  bool operator ==(Object other) =>
      other is AnswerPaper &&
      other.size == size &&
      other.orientation == orientation &&
      other.pages == pages &&
      other.rule == rule;

  @override
  int get hashCode => Object.hash(size, orientation, pages, rule);
}

/// 一卷的纸张配置：一个全局默认 + 每题覆盖（用户第 1 条：全局默认必须有，
/// 每题也要能单独设——证明题就是要多张）。
class AnswerPaperData {
  const AnswerPaperData({
    this.fallback = AnswerPaper.defaults,
    this.byQuestion = const <String, AnswerPaper>{},
  });

  factory AnswerPaperData.fromJson(Map<String, Object?>? json) {
    if (json == null) {
      return const AnswerPaperData();
    }
    final Map<String, AnswerPaper> perQuestion = <String, AnswerPaper>{};
    final Object? raw = json['by_question'];
    if (raw is Map) {
      raw.forEach((Object? key, Object? value) {
        if (key is String && key.isNotEmpty && value is Map) {
          perQuestion[key] = AnswerPaper.fromJson(
            value.cast<String, Object?>(),
          );
        }
      });
    }
    return AnswerPaperData(
      fallback: AnswerPaper.fromJson(
        (json['default'] as Map?)?.cast<String, Object?>(),
      ),
      byQuestion: perQuestion,
    );
  }

  static const AnswerPaperData empty = AnswerPaperData();

  final AnswerPaper fallback;
  final Map<String, AnswerPaper> byQuestion;

  bool get isEmpty => byQuestion.isEmpty;

  /// 这道题用哪份配置：有覆盖用覆盖，否则回落全局默认。
  AnswerPaper forQuestion(String questionId) =>
      byQuestion[questionId] ?? fallback;

  AnswerPaperData withDefault(AnswerPaper paper) =>
      AnswerPaperData(fallback: paper, byQuestion: byQuestion);

  AnswerPaperData withQuestion(String questionId, AnswerPaper paper) {
    final Map<String, AnswerPaper> next =
        Map<String, AnswerPaper>.of(byQuestion)..[questionId] = paper;
    return AnswerPaperData(fallback: fallback, byQuestion: next);
  }

  /// 删掉某题的覆盖（回到默认）。
  AnswerPaperData withoutQuestion(String questionId) {
    if (!byQuestion.containsKey(questionId)) {
      return this;
    }
    final Map<String, AnswerPaper> next =
        Map<String, AnswerPaper>.of(byQuestion)..remove(questionId);
    return AnswerPaperData(fallback: fallback, byQuestion: next);
  }

  AnswerPaperData retain(Set<String> keep) {
    final Map<String, AnswerPaper> next = <String, AnswerPaper>{
      for (final MapEntry<String, AnswerPaper> e in byQuestion.entries)
        if (keep.contains(e.key)) e.key: e.value,
    };
    return next.length == byQuestion.length
        ? this
        : AnswerPaperData(fallback: fallback, byQuestion: next);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'default': fallback.toJson(),
    'by_question': <String, Object?>{
      for (final MapEntry<String, AnswerPaper> e in byQuestion.entries)
        e.key: e.value.toJson(),
    },
  };
}
