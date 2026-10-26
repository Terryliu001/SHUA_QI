import 'package:shuaqi/domain/region/region_rect.dart';

/// 机器抽取文本的来源。**必须随题面一起交给 AI**，否则模型会把
/// PDF 文本层/OCR 的碎片当成事实，公式题尤其容易编错。
enum TextProvenance {
  /// 没有机器文本（扫描件 / 用户选择只给图）。
  none,

  /// PDF 文本层（位置可靠、公式顺序可能乱、私有区可能缺字）。
  pdfTextLayer,

  /// 图像 OCR（有识别错误，公式可能被拆成多行）。
  ocr,
}

extension TextProvenanceLabel on TextProvenance {
  String get label => switch (this) {
    TextProvenance.none => '无机器文本',
    TextProvenance.pdfTextLayer => 'PDF 文本层',
    TextProvenance.ocr => '图像 OCR',
  };
}

/// 交给 AI 的**一道题**载荷（第 5/6 周接入真实模型前的准备）。
///
/// 设计口径（用户 2026-10-23）：
/// - **图片是权威来源**：题面裁图来自 PDF 原页，公式/符号不会被转写破坏；
/// - 机器文本只作辅助，必须带来源声明；
/// - 数学/符号多的题，宁可不附文本，也不要把乱序碎片喂给模型。
class QuestionAiPayload {
  const QuestionAiPayload({
    required this.questionId,
    required this.label,
    required this.pageIndex,
    required this.rect,
    required this.imageAuthoritative,
    required this.provenance,
    this.extractedText,
  });

  final String questionId;
  final String label;
  final int pageIndex;

  /// 题面在页面坐标（pt）中的裁切区域。
  final RegionRect rect;

  /// 恒为 true：当前产品的图片来自 PDF 原页，是比文本更可信的来源。
  final bool imageAuthoritative;

  final TextProvenance provenance;

  /// 可为空。为空时 prompt 会明确写"只有图片"。
  final String? extractedText;

  /// 给模型/接口的说明文本。**不要把这一段省掉**：它解释了"文本是怎么来的"。
  String get declaration {
    final String source = provenance.label;
    return '输入包含两部分：题面图片（PDF 原页裁切，权威来源）'
        '${extractedText == null || extractedText!.trim().isEmpty ? '；本题不附机器抽取文本。' : '；另有$source抽取文本，仅作辅助，可能缺字、错序或把公式拆成碎片。'}'
        '图片与文本冲突时，以图片为准；不要根据乱序文本补写公式。';
  }

  /// 第 6 周可直接作为提示词的前半段。
  String get prompt =>
      '你是一位耐心的讲题老师。\n'
      '$declaration\n'
      '题号：$label（第 ${pageIndex + 1} 页）。\n'
      '请先看图理解题意，再分步骤讲解；不要编造图片里没有的条件或数字。\n'
      '如果题目本身看不清，请直接说明"题面不清晰"，不要猜。';

  Map<String, Object?> toJson() => <String, Object?>{
    'question_id': questionId,
    'label': label,
    'page_index': pageIndex,
    'rect': <String, Object?>{
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
    },
    'image_authoritative': imageAuthoritative,
    'text_provenance': provenance.name,
    'extracted_text': extractedText,
    'declaration': declaration,
    'prompt': prompt,
  };
}

/// 构造一份题面载荷。数学/符号题可以传 `text: null`，只交图片。
QuestionAiPayload buildQuestionAiPayload({
  required String questionId,
  required String label,
  required int pageIndex,
  required RegionRect rect,
  String? text,
  TextProvenance provenance = TextProvenance.none,
}) {
  final String? trimmed = text?.trim();
  return QuestionAiPayload(
    questionId: questionId,
    label: label,
    pageIndex: pageIndex,
    rect: rect,
    imageAuthoritative: true,
    provenance: (trimmed == null || trimmed.isEmpty)
        ? TextProvenance.none
        : provenance,
    extractedText: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
  );
}
