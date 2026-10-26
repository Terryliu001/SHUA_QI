import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ai/question_payload.dart';
import 'package:shuaqi/domain/region/region_rect.dart';

void main() {
  const RegionRect rect = RegionRect(left: 10, top: 20, width: 300, height: 80);

  test('只交图片：声明必须说明文本为空、图片权威', () {
    final QuestionAiPayload payload = buildQuestionAiPayload(
      questionId: 'q1',
      label: '1.',
      pageIndex: 2,
      rect: rect,
      text: null,
    );
    expect(payload.imageAuthoritative, isTrue);
    expect(payload.provenance, TextProvenance.none);
    expect(payload.extractedText, isNull);
    expect(payload.declaration, contains('图片'));
    expect(payload.declaration, contains('不附机器抽取文本'));
    expect(payload.prompt, contains('以图片为准'));
    expect(payload.toJson()['image_authoritative'], isTrue);
  });

  test('附 PDF 文本层：声明来源与"可能错序"', () {
    final QuestionAiPayload payload = buildQuestionAiPayload(
      questionId: 'q2',
      label: '2.',
      pageIndex: 0,
      rect: rect,
      text: '设 f(x)=x',
      provenance: TextProvenance.pdfTextLayer,
    );
    expect(payload.provenance, TextProvenance.pdfTextLayer);
    expect(payload.declaration, contains('PDF 文本层'));
    expect(payload.declaration, contains('错序'));
    expect(payload.toJson()['text_provenance'], 'pdfTextLayer');
  });

  test('空白文本视为无文本', () {
    final QuestionAiPayload payload = buildQuestionAiPayload(
      questionId: 'q3',
      label: '3.',
      pageIndex: 0,
      rect: rect,
      text: '   ',
      provenance: TextProvenance.ocr,
    );
    expect(payload.provenance, TextProvenance.none);
    expect(payload.extractedText, isNull);
  });
}
