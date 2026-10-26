import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_scale.dart';

/// 答题卡纸张（2026-10-24 C 批）与换尺寸时的笔迹搬移。
void main() {
  group('AnswerPaper 尺寸', () {
    test('默认 = 原来的 1000×600 横版', () {
      const AnswerPaper paper = AnswerPaper.defaults;
      expect(paper.widthPt, 1000);
      expect(paper.heightPt, 600);
      expect(paper.pages, 1);
      expect(paper.rule, AnswerPaperRule.lines);
    });

    test('A4 横竖只交换宽高', () {
      const AnswerPaper landscape = AnswerPaper(size: AnswerPaperSize.a4);
      expect(landscape.widthPt, 842);
      expect(landscape.heightPt, 595);
      const AnswerPaper portrait = AnswerPaper(
        size: AnswerPaperSize.a4,
        orientation: AnswerPaperOrientation.portrait,
      );
      expect(portrait.widthPt, 595);
      expect(portrait.heightPt, 842);
    });

    test('B5 竖版是 499×709', () {
      const AnswerPaper paper = AnswerPaper(
        size: AnswerPaperSize.b5,
        orientation: AnswerPaperOrientation.portrait,
      );
      expect(paper.widthPt, 499);
      expect(paper.heightPt, 709);
    });

    // 2026-10-24 第二轮：上限从 4 提到 9（用户要求"上限 9 张（不显示）"）。
    test('张数被收敛到 1..9', () {
      expect(AnswerPaper.maxPages, 9);
      expect(const AnswerPaper().copyWith(pages: 99).pages, 9);
      expect(const AnswerPaper().copyWith(pages: 0).pages, 1);
      expect(AnswerPaper.fromJson(<String, Object?>{'pages': 7}).pages, 7);
      expect(AnswerPaper.fromJson(<String, Object?>{'pages': 0}).pages, 1);
      expect(AnswerPaper.fromJson(<String, Object?>{'pages': 20}).pages, 9);
    });

    test('JSON 往返', () {
      const AnswerPaper paper = AnswerPaper(
        size: AnswerPaperSize.a4,
        orientation: AnswerPaperOrientation.portrait,
        pages: 3,
        rule: AnswerPaperRule.dots,
      );
      final AnswerPaper round = AnswerPaper.fromJson(paper.toJson());
      expect(round, paper);
    });
  });

  group('AnswerPaperData 每题覆盖', () {
    test('没有覆盖时回落全局默认', () {
      const AnswerPaperData data = AnswerPaperData(
        fallback: AnswerPaper(pages: 2),
      );
      expect(data.forQuestion('q1').pages, 2);
    });

    test('有覆盖时用覆盖', () {
      final AnswerPaperData data = const AnswerPaperData().withQuestion(
        'q1',
        const AnswerPaper(pages: 4, size: AnswerPaperSize.a4),
      );
      expect(data.forQuestion('q1').pages, 4);
      expect(data.forQuestion('q2').pages, 1);
    });

    test('retain 清掉已删题', () {
      final AnswerPaperData data = const AnswerPaperData()
          .withQuestion('q1', const AnswerPaper(pages: 2))
          .withQuestion('q2', const AnswerPaper(pages: 3));
      expect(data.retain(<String>{'q1'}).byQuestion.keys, <String>['q1']);
    });
  });

  group('scaleInkDoc', () {
    InkDoc docAt(double x, double y) => InkDoc(
      revision: 1,
      strokes: <InkStroke>[
        InkStroke(
          uid: 'a',
          points: <InkPoint>[InkPoint(x: x, y: y, pressure: 0.4, t: 7)],
        ),
      ],
    );

    test('按比例搬坐标，样式/压力/时间不变', () {
      final InkDoc scaled = scaleInkDoc(
        docAt(500, 300),
        fromWidth: 1000,
        fromHeight: 600,
        toWidth: 500,
        toHeight: 1200,
      );
      final InkPoint point = scaled.strokes.single.points.single;
      expect(point.x, 250);
      expect(point.y, 600);
      expect(point.pressure, 0.4);
      expect(point.t, 7);
      expect(scaled.strokes.single.uid, 'a');
    });

    test('尺寸一致时原样返回', () {
      final InkDoc doc = docAt(1, 2);
      expect(
        identical(
          scaleInkDoc(
            doc,
            fromWidth: 1000,
            fromHeight: 600,
            toWidth: 1000,
            toHeight: 600,
          ),
          doc,
        ),
        isTrue,
      );
    });

    test('空笔迹 / 非法尺寸不炸', () {
      expect(
        scaleInkDoc(
          InkDoc.empty,
          fromWidth: 1000,
          fromHeight: 600,
          toWidth: 595,
          toHeight: 842,
        ).strokes,
        isEmpty,
      );
      expect(
        scaleInkDoc(
          docAt(1, 1),
          fromWidth: 0,
          fromHeight: 600,
          toWidth: 595,
          toHeight: 842,
        ).strokes.length,
        1,
      );
    });
  });
}
