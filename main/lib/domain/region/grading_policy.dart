import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/region/grading_rules.dart';

/// 本地判题的"能不能信"（纯 Dart，2026-10-26 用户口径）。
///
/// 用户要的是：**先本地判，判不出或结果不可信时再问要不要交给 AI**。
/// 所以这里把"判出什么"和"这个结论能不能直接落库"分开：
/// - [GradeReadiness.ready]：结论可信，落 auto，指示灯立刻变绿/红；
/// - [GradeReadiness.untrusted]：有结论或只能给 pending，但**不落红点**，
///   先标黄，弹窗问用户是否 AI 判；
/// - [GradeReadiness.noAnswer]：没有参考答案，入口直接不可用；
/// - [GradeReadiness.noWork]：有答案但没作答，只展示参考答案。
enum GradeReadiness { ready, untrusted, noAnswer, noWork }

/// 一次本地判题的结果。
class LocalGrade {
  const LocalGrade({
    required this.readiness,
    required this.verdict,
    this.tentative,
    this.forceable = false,
    this.reason = '',
  });

  final GradeReadiness readiness;

  /// 可信时是最终结论；不可信时一律 [AnswerVerdict.pending]（黄点）。
  final AnswerVerdict verdict;

  /// 本地规则实际算出来的倾向（即使不可信也可能有）。
  ///
  /// 2026-10-28 用户口径：对答案弹窗里的「判题」= 按本地结论落判。
  /// 低置信度的客观题可以强制落绿/红（结果里注明低置信）；主观/公式
  /// 没有可强制的结论，[forceable] 为 false。
  final AnswerVerdict? tentative;

  /// [tentative] 是否可以拿去落库（低置信客观题 = true；主观/公式 = false）。
  final bool forceable;

  /// 给用户看的一句原因（弹窗里用）。
  final String reason;

  bool get canApply => readiness == GradeReadiness.ready;
}

/// 本地判一道题。
///
/// [ocrConfidence] 来自 ML Kit；0 表示"没有置信度信息/手工录入"，
/// 不按低置信处理。低于 [trustedOcrConfidence] 时，即使本地判出对错，
/// 也降级为不可信——手写识别错一个字母就会把"对"判成"错"，比黄点更伤信任。
LocalGrade judgeLocally({
  required String reference,
  required String studentText,
  required double ocrConfidence,
  required bool hasWork,
}) {
  final String ref = reference.trim();
  if (ref.isEmpty) {
    return const LocalGrade(
      readiness: GradeReadiness.noAnswer,
      verdict: AnswerVerdict.none,
      reason: '还没有参考答案',
    );
  }
  if (!hasWork) {
    return const LocalGrade(
      readiness: GradeReadiness.noWork,
      verdict: AnswerVerdict.none,
      reason: '这道题还没有作答',
    );
  }

  final String text = studentText.trim();
  final AnswerVerdict? verdict = judgeObjective(answer: text, reference: ref);

  // 主观题/公式/长答案：本地规则明确判不了，交 AI 或人工。
  if (verdict == null || verdict == AnswerVerdict.none) {
    return const LocalGrade(
      readiness: GradeReadiness.untrusted,
      verdict: AnswerVerdict.pending,
      reason: '本地规则判不了这道题（主观/公式/没有识别文本）',
    );
  }
  if (looksSubjective(ref)) {
    return LocalGrade(
      readiness: GradeReadiness.untrusted,
      verdict: AnswerVerdict.pending,
      tentative: verdict,
      reason: '参考答案更像主观题，本地只做客观题比对',
    );
  }
  if (text.isNotEmpty &&
      ocrConfidence > 0 &&
      ocrConfidence < trustedOcrConfidence) {
    return LocalGrade(
      readiness: GradeReadiness.untrusted,
      verdict: AnswerVerdict.pending,
      tentative: verdict,
      // 低置信度仍允许用户点「判题」强制按本地结论落判，
      // 但结果里必须注明，不能假装可信。
      forceable: true,
      reason: '手写识别置信度偏低（${(ocrConfidence * 100).round()}%），本地结论可能不准',
    );
  }
  return LocalGrade(
    readiness: GradeReadiness.ready,
    verdict: verdict,
    tentative: verdict,
    forceable: true,
    reason: verdict == AnswerVerdict.correct ? '与参考答案一致' : '与参考答案不一致',
  );
}

/// 低于这个识别置信度，本地结论一律降级为"不可信"。
const double trustedOcrConfidence = 0.65;
