/// 提示词策略（纯 Dart）。**只属于 app/domain，不下沉到客户端**。
///
/// 依据：
/// - 题面图片是权威来源，机器文本必须带来源声明（`QuestionAiPayload.declaration`）；
/// - 对话是"讲题"，**不做判分**；判题走单独的严格 JSON 任务；
/// - 公式统一 LaTeX（`$…$` / `$$…$$`），只使用 KaTeX 常用子集。
library;

import 'package:shuaqi/domain/ai/question_payload.dart';

/// 单题输入的长度上限（开发指南 07 成本控制：题干 ≤1500、识别文本 ≤2000）。
const int kMaxStemChars = 1500;
const int kMaxOcrChars = 2000;

/// 截断到上限，并明确告诉模型"后面被截了"，避免它编。
String clipText(String raw, int maxChars) {
  final String text = raw.trim();
  if (text.length <= maxChars) {
    return text;
  }
  return '${text.substring(0, maxChars)}\n（文本过长，已截断）';
}

/// 输入声明：有图时说图片权威；只发文本时**不能**让模型以为看到了图。
String _declaration(QuestionAiPayload payload, {required bool imagesIncluded}) {
  if (imagesIncluded) {
    return payload.declaration;
  }
  return '本题不附图片，只提供机器抽取文本（可能有缺字、错序，公式可能被拆成碎片）。'
      '请以文本为准；信息不足时明确说“题面信息不足”，不要猜。';
}

/// 对话 system。
String chatSystem(
  QuestionAiPayload payload, {
  String? referenceAnswer,
  bool imagesIncluded = true,
  bool deepThinking = false,
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('你是一位耐心的讲题老师，正在和一名学生一起看他正在做的题。')
    ..writeln(_declaration(payload, imagesIncluded: imagesIncluded))
    ..writeln('题号：${payload.label}（第 ${payload.pageIndex + 1} 页）。');
  if (payload.extractedText != null &&
      payload.extractedText!.trim().isNotEmpty) {
    buffer.writeln('机器抽取文本（仅辅助，可能有错字/错序）：');
    buffer.writeln(clipText(payload.extractedText!, kMaxStemChars));
  }
  final String? reference = referenceAnswer?.trim();
  if (reference != null && reference.isNotEmpty) {
    buffer.writeln('参考答案（仅辅助，以题面为准）：');
    buffer.writeln(clipText(reference, 800));
  }
  buffer
    ..writeln('回答规则：')
    ..writeln(
      imagesIncluded
          ? '1. 先理解图片中的题面，再回答；图片与文本冲突时以图片为准。'
          : '1. 先理解文本中的题面，再回答；信息不足就直说。',
    )
    ..writeln('2. 用中文，先给结论再解释；步骤分点、短句，别写长篇大论。')
    ..writeln('3. 公式一律 LaTeX：行内 \$…\$、独占一行 \$\$…\$\$；只用 KaTeX 常用子集。')
    ..writeln('4. 不要编造题面没有的条件或数字；看不清就说“题面不清晰”，不要猜。')
    ..writeln('5. 这是讲解对话：可以指出学生思路的问题，但**不判分、不打分、不说“扣分/不得分”**。');
  if (deepThinking) {
    buffer.writeln(
      '6. 本轮开启深度思考：先在推理里充分分析题意、尝试不同思路并自检，'
      '再把**简洁、确定的结论**放在最终回答里；不要把推理草稿塞进最终回答。',
    );
  }
  return buffer.toString();
}

/// 对话任务的第一条 user 文本（图片就挂在这条上）。
String chatIntro(
  QuestionAiPayload payload, {
  List<String> imageLabels = const <String>[],
}) {
  final StringBuffer buffer = StringBuffer(
    '这是当前题目（第 ${payload.pageIndex + 1} 页，题号 ${payload.label}）。',
  );
  if (imageLabels.isNotEmpty) {
    buffer.write('附图依次为：${imageLabels.join('、')}。');
  }
  buffer.write('请先看清题面，再回答我接下来的问题。');
  return buffer.toString();
}

/// "先做一遍"的 system：要求严格 JSON，便于落答案库。
String solveSystem(QuestionAiPayload payload, {bool imagesIncluded = true}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('你是一位解题老师。请独立解出这道题，并给出最终答案与分步解析。')
    ..writeln(_declaration(payload, imagesIncluded: imagesIncluded))
    ..writeln('题号：${payload.label}（第 ${payload.pageIndex + 1} 页）。');
  if (payload.extractedText != null &&
      payload.extractedText!.trim().isNotEmpty) {
    buffer.writeln('机器抽取文本（仅辅助，可能有错字/错序）：');
    buffer.writeln(clipText(payload.extractedText!, kMaxStemChars));
  }
  buffer
    ..writeln('只输出一个 JSON 对象，不要 markdown 代码块，不要解释 JSON 以外的文字：')
    ..writeln(
      '{"answer":"最终答案，尽量简短，公式用 \$…\$",'
      '"explanation":"中文分步解析，公式用 \$…\$ 或 \$\$…\$\$",'
      '"confidence":0.0}',
    )
    ..writeln('规则：')
    ..writeln(
      imagesIncluded
          ? '- 以图片为准；看不清题面时 answer 写“题面不清晰”，不要猜。'
          : '- 以文本为准；信息不足时 answer 写“题面不清晰”，不要猜。',
    )
    ..writeln('- answer 只写学生该填的最终结果，不要把解析塞进去。')
    ..writeln('- confidence 是 0–1 的小数，表示你对答案的把握。');
  return buffer.toString();
}

String solveUser() => '请解这道题，先给最终答案，再给分步解析。';

/// 判题的 system：严格 JSON + 不确定就 pending。
String gradeSystem(
  QuestionAiPayload payload, {
  String? referenceAnswer,
  bool imagesIncluded = true,
}) {
  final String reference = (referenceAnswer ?? '').trim();
  final StringBuffer buffer = StringBuffer()
    ..writeln('你是批改助手。请判断学生这道题的作答是否正确。')
    ..writeln(_declaration(payload, imagesIncluded: imagesIncluded))
    ..writeln('题号：${payload.label}（第 ${payload.pageIndex + 1} 页）。');
  if (payload.extractedText != null &&
      payload.extractedText!.trim().isNotEmpty) {
    buffer.writeln('题面机器文本（仅辅助，可能有错字/错序）：');
    buffer.writeln(clipText(payload.extractedText!, kMaxStemChars));
  }
  if (reference.isEmpty) {
    buffer.writeln('本题没有收录参考答案：请先自己解题，再对照学生作答判断。');
  } else {
    buffer.writeln('参考答案（优先依据）：');
    buffer.writeln(clipText(reference, 1200));
  }
  buffer
    ..writeln('只输出一个 JSON 对象，不要 markdown 代码块，不要输出 JSON 以外的文字：')
    ..writeln(
      '{"verdict":"correct|wrong|pending","reason":"一句话依据（中文，指出关键差异）",'
      '"confidence":0.0}',
    )
    ..writeln('判定规则：')
    ..writeln('- 学生作答看不清、信息不足、或你无法确定 → pending，**绝不猜**。')
    ..writeln('- 数值/表达式按数学等价判断（0.5 与 1/2、等价变形都算对）。')
    ..writeln('- 多解题只要学生给出其中一个正确解 → correct。')
    ..writeln('- reason 只讲依据，不要训斥、不要写“扣几分”。')
    ..writeln('- confidence 是 0–1 的小数。');
  return buffer.toString();
}

/// 判题的 user 文本。学生作答图作为图片附件（如果有）。
String gradeUser({
  required String studentAnswerText,
  String? referenceAnswer,
  bool hasAnswerImage = false,
}) {
  final String text = studentAnswerText.trim();
  final StringBuffer buffer = StringBuffer()
    ..writeln(hasAnswerImage ? '学生作答见附图（手写原图，权威）。' : '学生作答（手写识别文本，可能有错字）：');
  if (text.isNotEmpty) {
    buffer.writeln(clipText(text, kMaxOcrChars));
  } else if (!hasAnswerImage) {
    buffer.writeln('（没有识别出文字，也没有作答图）');
  }
  final String reference = (referenceAnswer ?? '').trim();
  if (reference.isNotEmpty) {
    buffer.writeln('参考答案：');
    buffer.writeln(clipText(reference, 1200));
  }
  buffer.writeln('请只输出 JSON。');
  return buffer.toString();
}
