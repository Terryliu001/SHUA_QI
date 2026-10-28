/// 判题（改卷）的结果模型 —— 纯 Dart。
///
/// 为什么单独一个文件、单独一个枚举，而不是复用 `RegionGrade`：
/// `RegionGrade` 是**切题置信度**（green/yellow/red 按 confidence 分档），
/// 跟"这道题答对了没有"毫无关系。两者同名不同义在 2026-10-24 的代码里已经
/// 埋过一次语义陷阱（`RegionMark.grade` 被填成置信度），这里明确拆开。
library;

/// 一道题的判定结果。
enum AnswerVerdict {
  /// 没判：没有参考答案，或还没有作答。
  none,

  /// 判对。
  correct,

  /// 判错。
  wrong,

  /// 待判：客观题比对不了（主观题/公式），需要 AI 或人工。
  pending;

  static AnswerVerdict decode(String? raw) {
    for (final AnswerVerdict value in values) {
      if (value.name == raw) {
        return value;
      }
    }
    return AnswerVerdict.none;
  }

  /// 面板上的三色点：绿 / 黄 / 红；`none` 不画点。
  bool get isMarked => this != AnswerVerdict.none;
}

/// 结果来源：自动判的会被重算覆盖，用户手改的永远保留。
///
/// - `auto`：本地规则；
/// - `manual`：用户三色手改；
/// - `ai`：模型判的（2026-10-24 接入）。本地一键改卷**不覆盖** AI 结论，
///   否则刚花 token 判完的主观题会被下一次"改卷"打回 pending。
enum GradeSource {
  auto,
  manual,
  ai;

  static GradeSource decode(String? raw) {
    for (final GradeSource source in values) {
      if (source.name == raw) {
        return source;
      }
    }
    return auto;
  }
}

/// 一次判题所用的「依据快照」。
///
/// 为什么要存下来：改卷需要判断「AI 判过之后答案有没有大改」。
/// 只存 verdict 时，下一次改卷只能靠当前 OCR 猜；存了这几项才能做到：
/// - 参考答案换了 → 重判；
/// - OCR 文本大改 → 重判；
/// - 只多写了一个标点 / 重写同一答案 → 保留 AI 原判，不重复扣 token。
class GradeEvidence {
  const GradeEvidence({this.text = '', this.sig = '', this.refHash = ''});

  static const GradeEvidence empty = GradeEvidence();

  /// 判题时使用的 OCR 文本。
  final String text;

  /// 判题时的作答指纹（见 `answer_freshness.dart`）。
  final String sig;

  /// 判题时使用的参考答案哈希。
  final String refHash;

  bool get isEmpty => text.isEmpty && sig.isEmpty && refHash.isEmpty;
}

/// 一道题的判题记录。
class QuestionGrade {
  const QuestionGrade({
    required this.questionId,
    required this.verdict,
    this.source = GradeSource.auto,
    this.at = 0,
    this.note = '',
    this.judgedText = '',
    this.judgedSig = '',
    this.judgedRefHash = '',
  });

  factory QuestionGrade.fromJson(Map<String, Object?> json) => QuestionGrade(
    questionId: (json['question_id'] as String?) ?? '',
    verdict: AnswerVerdict.decode(json['verdict'] as String?),
    source: GradeSource.decode(json['source'] as String?),
    at: (json['at'] as num?)?.toInt() ?? 0,
    note: (json['note'] as String?) ?? '',
    judgedText: (json['judged_text'] as String?) ?? '',
    judgedSig: (json['judged_sig'] as String?) ?? '',
    judgedRefHash: (json['judged_ref_hash'] as String?) ?? '',
  );

  final String questionId;
  final AnswerVerdict verdict;
  final GradeSource source;
  final int at;

  /// 人工备注（例如"识别不准，实际答对"）。
  final String note;

  /// 判题快照（0.1.3 起）。旧记录为空，按「没有快照」保守处理。
  final String judgedText;
  final String judgedSig;
  final String judgedRefHash;

  GradeEvidence get evidence =>
      GradeEvidence(text: judgedText, sig: judgedSig, refHash: judgedRefHash);

  bool get hasEvidence =>
      judgedText.isNotEmpty || judgedSig.isNotEmpty || judgedRefHash.isNotEmpty;

  bool get manual => source == GradeSource.manual;

  bool get fromAi => source == GradeSource.ai;

  QuestionGrade copyWith({
    AnswerVerdict? verdict,
    GradeSource? source,
    int? at,
    String? note,
    String? judgedText,
    String? judgedSig,
    String? judgedRefHash,
  }) => QuestionGrade(
    questionId: questionId,
    verdict: verdict ?? this.verdict,
    source: source ?? this.source,
    at: at ?? this.at,
    note: note ?? this.note,
    judgedText: judgedText ?? this.judgedText,
    judgedSig: judgedSig ?? this.judgedSig,
    judgedRefHash: judgedRefHash ?? this.judgedRefHash,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'question_id': questionId,
    'verdict': verdict.name,
    'source': source.name,
    'at': at,
    'note': note,
    'judged_text': judgedText,
    'judged_sig': judgedSig,
    'judged_ref_hash': judgedRefHash,
  };
}

/// 一卷的判题结果，按 `questionId` 存。
class GradingData {
  const GradingData(this.grades);

  static const GradingData empty = GradingData(<String, QuestionGrade>{});

  final Map<String, QuestionGrade> grades;

  bool get isEmpty => grades.isEmpty;

  AnswerVerdict verdictOf(String questionId) =>
      grades[questionId]?.verdict ?? AnswerVerdict.none;

  QuestionGrade? gradeOf(String questionId) => grades[questionId];

  GradingData withGrade(QuestionGrade grade) {
    final Map<String, QuestionGrade> next = Map<String, QuestionGrade>.of(
      grades,
    )..[grade.questionId] = grade;
    return GradingData(next);
  }

  GradingData without(String questionId) {
    if (!grades.containsKey(questionId)) {
      return this;
    }
    final Map<String, QuestionGrade> next = Map<String, QuestionGrade>.of(
      grades,
    )..remove(questionId);
    return GradingData(next);
  }

  /// 只保留还存在的题（删题/重切后清幽灵记录）。
  GradingData retain(Set<String> keep) {
    final Map<String, QuestionGrade> next = <String, QuestionGrade>{
      for (final MapEntry<String, QuestionGrade> e in grades.entries)
        if (keep.contains(e.key)) e.key: e.value,
    };
    return next.length == grades.length ? this : GradingData(next);
  }

  /// 统计：按判定分桶（只数传进来的 id，避免把已删题算进去）。
  VerdictCounts countsOf(Iterable<String> questionIds) {
    int correct = 0;
    int wrong = 0;
    int pending = 0;
    int none = 0;
    for (final String id in questionIds) {
      switch (verdictOf(id)) {
        case AnswerVerdict.correct:
          correct += 1;
        case AnswerVerdict.wrong:
          wrong += 1;
        case AnswerVerdict.pending:
          pending += 1;
        case AnswerVerdict.none:
          none += 1;
      }
    }
    return VerdictCounts(
      correct: correct,
      wrong: wrong,
      pending: pending,
      none: none,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'grades': <Map<String, Object?>>[
      for (final QuestionGrade grade in grades.values) grade.toJson(),
    ],
  };

  factory GradingData.fromJson(Map<String, Object?>? json) {
    final Object? raw = json?['grades'];
    if (raw is! List) {
      return empty;
    }
    final Map<String, QuestionGrade> next = <String, QuestionGrade>{};
    for (final Object? item in raw) {
      if (item is! Map) {
        continue;
      }
      final QuestionGrade grade = QuestionGrade.fromJson(
        item.cast<String, Object?>(),
      );
      if (grade.questionId.isNotEmpty) {
        next[grade.questionId] = grade;
      }
    }
    return GradingData(next);
  }
}

/// 一次改卷的统计。
class VerdictCounts {
  const VerdictCounts({
    this.correct = 0,
    this.wrong = 0,
    this.pending = 0,
    this.none = 0,
  });

  final int correct;
  final int wrong;
  final int pending;
  final int none;

  int get total => correct + wrong + pending + none;

  bool get isEmpty => total == 0;
}
