import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/answer/answer_paper.dart';

/// 答题纸的纸样式（横线 / 虚线 / 点阵 / 方格 / 空白）。
///
/// 2026-10-25 从 `answer_sheet_page.dart` 抽出来：答题卡与「收藏重刷」用的是
/// 同一套纸样式口径，两处各画一份迟早会歪（线距、颜色、留白）。
///
/// 全部按**纸张 pt 坐标**排布再缩放，所以换 A4/B5 时线距不会变（始终 36pt ≈ 1.27cm），
/// 而不是"屏幕上固定像素间距"——后者在竖版 A4 上会密到看不清。
class AnswerPaperPainter extends CustomPainter {
  const AnswerPaperPainter({
    required this.color,
    required this.rule,
    required this.widthPt,
    required this.heightPt,
  });

  final Color color;
  final AnswerPaperRule rule;
  final double widthPt;
  final double heightPt;

  /// 线距（pt）。36pt ≈ 12.7mm，接近常见横线本。
  static const double gapPt = 36;
  static const double marginPt = 18;

  @override
  void paint(Canvas canvas, Size size) {
    if (rule == AnswerPaperRule.blank || widthPt <= 0) {
      return;
    }
    final double scale = size.width / widthPt;
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final double left = marginPt * scale;
    final double right = size.width - marginPt * scale;
    final double gap = gapPt * scale;

    // 点阵纸：**只有点、没有线**（参考国誉方格本，点在格子交角，间距 18pt）。
    if (rule == AnswerPaperRule.dots) {
      final Paint dot = Paint()..color = color;
      final double step = gap / 2;
      for (double y = step; y < size.height - 2; y += step) {
        for (double x = left; x <= right; x += step) {
          canvas.drawCircle(Offset(x, y), 1.1, dot);
        }
      }
      return;
    }

    void horizontalLine(double y) {
      if (rule == AnswerPaperRule.dashed) {
        double x = left;
        while (x < right) {
          canvas.drawLine(
            Offset(x, y),
            Offset(math.min(x + 6 * scale, right), y),
            paint,
          );
          x += 10 * scale;
        }
      } else {
        canvas.drawLine(Offset(left, y), Offset(right, y), paint);
      }
    }

    for (double y = gap; y < size.height - 4; y += gap) {
      horizontalLine(y);
    }
    if (rule == AnswerPaperRule.grid) {
      for (double x = left + gap; x < right; x += gap) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
    }
  }

  @override
  bool shouldRepaint(AnswerPaperPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.rule != rule ||
      oldDelegate.widthPt != widthPt ||
      oldDelegate.heightPt != heightPt;
}
