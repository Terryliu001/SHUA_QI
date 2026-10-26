/// 客观题判题规则 —— **纯函数**，不碰 IO、不碰 Flutter，方便单测。
///
/// 能力边界（2026-10-24 用户拍板"本地规则 + AI 判主观题"）：
/// - **能判的**：选择题（参考答案是 A/B/C/D）、数值题、与参考答案完全一致或
///   参考答案被作答包含的填空/简答；
/// - **判不了的**：解答/证明/公式（参考答案很长、或含"证明/略"）→ 交给 AI，
///   本地只给 [AnswerVerdict.pending]，**绝不假装判错**；
/// - **没法判的**：没有参考答案、或没有作答文本 → [AnswerVerdict.none]。
library;

import 'package:shuaqi/domain/model/grading.dart';

/// 半角化 + 去噪。返回的字符串只用于**比较**，不回写任何地方。
String normalizeAnswerText(String raw) {
  if (raw.isEmpty) {
    return '';
  }
  final StringBuffer buffer = StringBuffer();
  for (final int code in raw.runes) {
    // 全角 ASCII（！..～）→ 半角；全角空格单独处理。
    if (code >= 0xFF01 && code <= 0xFF5E) {
      buffer.writeCharCode(code - 0xFEE0);
    } else if (code == 0x3000) {
      // 全角空格：丢掉
    } else if (code == 0x00D7) {
      buffer.write('x'); // × → x
    } else if (code == 0x00F7) {
      buffer.write('/'); // ÷ → /
    } else {
      buffer.writeCharCode(code);
    }
  }
  String text = buffer.toString();
  // 去掉所有空白（手写识别常带换行/空格）。
  text = text.replaceAll(RegExp(r'\s+'), '');
  // 去掉常见前缀。
  for (final String prefix in <String>['答案:', '答案：', '答:', '答：', '解:', '解：']) {
    if (text.startsWith(prefix)) {
      text = text.substring(prefix.length);
    }
  }
  // 去掉末尾标点。
  text = text.replaceAll(RegExp(r'[。.；;，,]+$'), '');
  return text.toLowerCase();
}

/// 参考答案是不是"主观题"（本地判不了，要 AI/人工）。
bool looksSubjective(String reference) {
  final String text = reference.trim();
  if (text.length > 20) {
    return true;
  }
  for (final String marker in <String>['证明', '略', '同上', '见图', '略述']) {
    if (text.contains(marker)) {
      return true;
    }
  }
  return false;
}

/// 从作答文本里抽选项字母。
///
/// 两种形态都要认：
/// - **纯字母串**（`AB`、`B`）——手写"多选"常常两个字母连着写；
/// - **独立字母**（`我觉得是B`、`选 B`）——前后不能紧邻其它字母，避免把
///   `BAD` 这种单词拆成 B/A/D。
Set<String> optionLettersOf(String answer) {
  final String text = normalizeAnswerText(answer).toUpperCase();
  if (text.isEmpty) {
    return <String>{};
  }
  if (RegExp(r'^[A-D]{1,4}$').hasMatch(text)) {
    return text.split('').toSet();
  }
  final Set<String> letters = <String>{};
  for (int i = 0; i < text.length; i++) {
    final String ch = text[i];
    if (!'ABCD'.contains(ch)) {
      continue;
    }
    final bool leftOk = i == 0 || !RegExp(r'[A-Z]').hasMatch(text[i - 1]);
    final bool rightOk =
        i == text.length - 1 || !RegExp(r'[A-Z]').hasMatch(text[i + 1]);
    if (leftOk && rightOk) {
      letters.add(ch);
    }
  }
  return letters;
}

/// 判一道题。
///
/// 返回 `null` 表示"本地判不了、需要 AI"——由上层决定落 [AnswerVerdict.pending]
/// 还是排队给模型。这里返回 null 而不是直接给 pending，是为了让"AI 判"和
/// "本地判不了"两件事在上层可以分开处理。
AnswerVerdict? judgeObjective({
  required String answer,
  required String reference,
}) {
  final String ref = normalizeAnswerText(reference);
  final String got = normalizeAnswerText(answer);
  if (ref.isEmpty) {
    return AnswerVerdict.none;
  }
  if (got.isEmpty) {
    return AnswerVerdict.none;
  }
  // 1) 选择题：参考答案就是一个选项字母。
  if (ref.length == 1 && 'abcd'.contains(ref)) {
    final Set<String> letters = optionLettersOf(got);
    if (letters.isEmpty) {
      return null; // 识别成了别的字，别硬判
    }
    return letters.contains(ref.toUpperCase())
        ? AnswerVerdict.correct
        : AnswerVerdict.wrong;
  }
  // 2) 数值：两边都能 parse 成数才比（容差按量级，避免浮点误差）。
  final double? refNumber = double.tryParse(ref.replaceAll(',', ''));
  final double? gotNumber = double.tryParse(got.replaceAll(',', ''));
  if (refNumber != null && gotNumber != null) {
    final double tolerance = 1e-6 * (refNumber.abs() < 1 ? 1 : refNumber.abs());
    return (refNumber - gotNumber).abs() <= tolerance
        ? AnswerVerdict.correct
        : AnswerVerdict.wrong;
  }
  // 3) 文本：完全一致，或作答里包含参考答案（手写常带多余符号）。
  if (got == ref) {
    return AnswerVerdict.correct;
  }
  if (ref.length >= 2 && got.contains(ref)) {
    return AnswerVerdict.correct;
  }
  // 4) 主观题不硬判。
  if (looksSubjective(reference)) {
    return null;
  }
  return AnswerVerdict.wrong;
}
