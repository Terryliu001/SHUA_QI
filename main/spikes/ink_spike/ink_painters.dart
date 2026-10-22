import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'page_ink_store.dart';
import 'stroke_model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 占位背景
// T0.2 刻意不接 pdfrx：这一阶段要衡量的是"画布本身"的帧率与延迟，
// 混进 PDF 渲染就分不清问题出在哪。合成页保留了试卷的视觉密度（题干条 + 作答横线），
// 足够判断"笔尖落点与横线对不对得上"。
// 只在 initState 里生成一次 Picture，之后每帧只是 drawPicture，不重复排版。
// ─────────────────────────────────────────────────────────────────────────────

ui.Picture buildFakeExamPage({
  required int pageIndex,
  required double pageWidth,
  required double pageHeight,
  required int questionCount,
}) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const double margin = 44;
  final Rect page = Rect.fromLTWH(0, 0, pageWidth, pageHeight);

  canvas.drawRect(page, Paint()..color = const Color(0xFFFFFDF8));

  final Paint border = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8
    ..color = const Color(0xFFB6BCC4);
  canvas.drawRect(page.deflate(margin - 18), border);

  _drawText(
    canvas,
    '模拟试卷 · 第 ${pageIndex + 1} 页',
    const Offset(margin, 40),
    15,
    FontWeight.w600,
    const Color(0xFF2B3138),
  );

  final Paint hairline = Paint()
    ..color = const Color(0xFF9AA3AD)
    ..strokeWidth = 0.9;
  canvas.drawLine(
    const Offset(margin, 66),
    Offset(pageWidth - margin, 66),
    hairline,
  );

  const double blockTop = 82;
  final double blockBottom = pageHeight - 58;
  final double blockHeight = (blockBottom - blockTop) / questionCount;
  final Paint stemBar = Paint()..color = const Color(0xFFE6E8E4);
  final Paint answerLine = Paint()
    ..color = const Color(0xFFCBD1D7)
    ..strokeWidth = 0.8;

  for (int i = 0; i < questionCount; i++) {
    final double y = blockTop + blockHeight * i;
    final int number = pageIndex * questionCount + i + 1;
    _drawText(
      canvas,
      '$number.',
      Offset(margin, y),
      12,
      FontWeight.w600,
      const Color(0xFF3A4149),
    );

    // 题干占位条：两行，宽度不同，模拟真实排版的不齐整
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(margin + 22, y + 1, blockHeight * 3.2, 5),
        const Radius.circular(2),
      ),
      stemBar,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(margin + 22, y + 12, blockHeight * 2.2, 5),
        const Radius.circular(2),
      ),
      stemBar,
    );

    // 作答横线：4 行
    final double firstLineY = y + 30;
    final double lineGap = (blockHeight - 40) / 4;
    for (int line = 0; line < 4; line++) {
      final double lineY = firstLineY + lineGap * line;
      canvas.drawLine(
        Offset(margin + 22, lineY),
        Offset(pageWidth - margin, lineY),
        answerLine,
      );
    }
  }

  _drawText(
    canvas,
    '— ${pageIndex + 1} / 5 —',
    Offset(pageWidth / 2 - 24, pageHeight - 42),
    11,
    FontWeight.w400,
    const Color(0xFF97A0A8),
  );

  return recorder.endRecording();
}

void _drawText(
  Canvas canvas,
  String text,
  Offset offset,
  double fontSize,
  FontWeight weight,
  Color color,
) {
  final TextPainter painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: fontSize, fontWeight: weight, color: color),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, offset);
}

// ─────────────────────────────────────────────────────────────────────────────
// 三个图层
// 背景 / 已提交笔迹 / 正在写的笔迹，各自独立 CustomPaint。
// 好处：落笔时只有最上面那层重绘，背景与已提交层一动不动。
// ─────────────────────────────────────────────────────────────────────────────

class FakePagePainter extends CustomPainter {
  FakePagePainter({required this.picture, required this.scale});

  final ui.Picture picture;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    canvas.drawPicture(picture);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant FakePagePainter oldDelegate) {
    return oldDelegate.picture != picture || oldDelegate.scale != scale;
  }
}

class CommittedInkPainter extends CustomPainter {
  CommittedInkPainter({
    required this.store,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final PageInkStore store;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    store.draw(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CommittedInkPainter oldDelegate) {
    return oldDelegate.store != store || oldDelegate.scale != scale;
  }
}

class ActiveStrokePainter extends CustomPainter {
  ActiveStrokePainter({
    required this.points,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  static final Paint _paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true
    ..color = const Color(0xFF14161A);

  final List<SpikePoint> points;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) {
      return;
    }
    canvas.save();
    canvas.scale(scale);

    if (points.length == 1) {
      final SpikePoint only = points.first;
      _paint.strokeWidth = _widthFor(only.pressure);
      canvas.drawCircle(
        Offset(only.x, only.y),
        _paint.strokeWidth / 2,
        Paint()..color = _paint.color,
      );
      canvas.restore();
      return;
    }

    for (int i = 1; i < points.length; i++) {
      final SpikePoint a = points[i - 1];
      final SpikePoint b = points[i];
      _paint.strokeWidth = _widthFor(b.pressure);
      canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), _paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ActiveStrokePainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.scale != scale;
  }

  /// 压感恒为 1.0（鼠标/触摸）时用中间宽度，避免整页糊成粗线。
  static double _widthFor(double pressure) {
    if (pressure <= 0 || pressure >= 0.999) {
      return 2.6;
    }
    return 1.2 + (4.6 - 1.2) * pressure;
  }
}
