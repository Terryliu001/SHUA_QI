import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/answer_sheet.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/region/answer_freshness.dart';
import 'package:shuaqi/domain/region/region_rect.dart';

void main() {
  AnswerSheetEntry entry({
    int pageIndex = 0,
    RegionRect rect = const RegionRect(
      left: 10,
      top: 20,
      width: 300,
      height: 200,
    ),
  }) => AnswerSheetEntry(
    questionId: 'q1',
    pageIndex: pageIndex,
    rect: rect,
    ocrText: 'B',
    ocrConfidence: 0.9,
    ocrEngine: 'ink_mlkit',
    ocrAt: 100,
    updatedAt: 100,
    inkSig: 'sig',
  );

  InkDoc doc({int revision = 1, int strokes = 1}) => InkDoc(
    revision: revision,
    strokes: <InkStroke>[
      for (int i = 0; i < strokes; i += 1)
        InkStroke(uid: 's$i', points: const <InkPoint>[InkPoint(x: 10, y: 10)]),
    ],
  );

  String signature({
    AnswerSheetEntry? data,
    List<InkDoc>? sheets,
    int pageRevision = 1,
    List<InkStroke>? pageStrokes,
    int paperPages = 1,
  }) => answerSignatureOf(
    entry: data ?? entry(),
    sheetDocs: sheets ?? <InkDoc>[doc()],
    pageRevision: pageRevision,
    pageStrokes: pageStrokes ?? const <InkStroke>[],
    paperPages: paperPages,
  );

  test('作答指纹：同一输入稳定，改框/加笔/加纸都会变', () {
    final String base = signature();
    expect(signature(), base);
    expect(
      signature(
        data: entry(
          rect: const RegionRect(left: 11, top: 20, width: 300, height: 200),
        ),
      ),
      isNot(base),
    );
    expect(signature(sheets: <InkDoc>[doc(strokes: 2)]), isNot(base));
    expect(
      signature(sheets: <InkDoc>[doc(), doc()], paperPages: 2),
      isNot(base),
    );
    expect(signature(pageRevision: 2), isNot(base));
  });

  test('文本相似度：一致为 1，空对空为 1，完全无关接近 0', () {
    expect(answerTextSimilarity('B', 'B'), 1);
    expect(answerTextSimilarity('', ''), 1);
    expect(answerTextSimilarity('B', ''), 0);
    expect(answerTextSimilarity('x=1', 'x=1'), 1);
    // 全角/空白/尾标点归一后仍然一致。
    expect(answerTextSimilarity('Ｂ 。', 'b'), 1);
    expect(answerTextSimilarity('abcd', 'wxyz'), lessThan(0.1));
  });

  test('明显改动：没有快照不重判；同样文字不重判；大改才重判', () {
    const QuestionGrade noSnapshot = QuestionGrade(
      questionId: 'q1',
      verdict: AnswerVerdict.correct,
      source: GradeSource.ai,
    );
    expect(
      isSignificantAnswerChange(
        grade: noSnapshot,
        currentText: '完全不同的答案',
        currentReference: 'B',
      ),
      isFalse,
    );

    final QuestionGrade snapshot = QuestionGrade(
      questionId: 'q1',
      verdict: AnswerVerdict.correct,
      source: GradeSource.ai,
      judgedText: 'B',
      judgedSig: signature(),
      judgedRefHash: referenceHashOf('B'),
    );
    expect(
      isSignificantAnswerChange(
        grade: snapshot,
        currentText: 'B',
        currentReference: 'B',
        currentSignature: signature(),
      ),
      isFalse,
    );
    // 多一个空格/尾标点不算大改。
    expect(
      isSignificantAnswerChange(
        grade: snapshot,
        currentText: ' B。 ',
        currentReference: 'B',
        currentSignature: signature(),
      ),
      isFalse,
    );
    // 从 B 变成完全不同的文字 = 大改。
    expect(
      isSignificantAnswerChange(
        grade: snapshot,
        currentText: 'C',
        currentReference: 'B',
        currentSignature: signature(),
      ),
      isTrue,
    );
    // 参考答案换了 = 大改。
    expect(
      isSignificantAnswerChange(
        grade: snapshot,
        currentText: 'B',
        currentReference: 'C',
        currentSignature: signature(),
      ),
      isTrue,
    );
  });

  test('参考答案哈希：归一化后稳定，不同答案不同', () {
    expect(referenceHashOf(' B。'), referenceHashOf('b'));
    expect(referenceHashOf('B'), isNot(referenceHashOf('C')));
    expect(referenceHashOf(null), referenceHashOf(''));
  });

  test('AnswerSheetEntry / QuestionGrade 的判题快照字段可 JSON 往返', () {
    final AnswerSheetEntry sheet = entry();
    final AnswerSheetEntry sheetBack = AnswerSheetEntry.fromJson(
      sheet.toJson(),
    );
    expect(sheetBack.inkSig, 'sig');

    const QuestionGrade grade = QuestionGrade(
      questionId: 'q1',
      verdict: AnswerVerdict.wrong,
      source: GradeSource.ai,
      judgedText: 'C',
      judgedSig: 'sig',
      judgedRefHash: 'ref',
    );
    final QuestionGrade back = QuestionGrade.fromJson(grade.toJson());
    expect(back.judgedText, 'C');
    expect(back.judgedSig, 'sig');
    expect(back.judgedRefHash, 'ref');
    expect(back.hasEvidence, isTrue);
  });
}
