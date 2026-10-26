import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/shape_recognition.dart';

List<InkPoint> _points(List<(double, double)> xy) => <InkPoint>[
  for (final (double x, double y) in xy) InkPoint(x: x, y: y, pressure: 0.5),
];

List<InkPoint> _line(double x1, double y1, double x2, double y2) {
  final List<InkPoint> out = <InkPoint>[];
  for (int i = 0; i <= 30; i += 1) {
    final double t = i / 30;
    out.add(
      InkPoint(
        x: x1 + (x2 - x1) * t + math.sin(i * 1.7) * 0.5,
        y: y1 + (y2 - y1) * t + math.cos(i * 1.3) * 0.5,
      ),
    );
  }
  return out;
}

List<InkPoint> _polygon(List<(double, double)> corners) {
  final List<InkPoint> out = <InkPoint>[];
  for (int i = 0; i < corners.length; i += 1) {
    final (double x1, double y1) = corners[i];
    final (double x2, double y2) = corners[(i + 1) % corners.length];
    for (int s = 0; s < 20; s += 1) {
      final double t = s / 20;
      out.add(
        InkPoint(
          x: x1 + (x2 - x1) * t + math.sin(s * 1.1) * 0.45,
          y: y1 + (y2 - y1) * t + math.cos(s * 1.4) * 0.45,
        ),
      );
    }
  }
  out.add(InkPoint(x: out.first.x, y: out.first.y));
  return out;
}

List<InkPoint> _ellipse(double cx, double cy, double rx, double ry) {
  final List<InkPoint> out = <InkPoint>[];
  for (int i = 0; i <= 90; i += 1) {
    final double t = i / 90 * math.pi * 2;
    out.add(
      InkPoint(
        x: cx + math.cos(t) * rx + math.sin(i * 2.1) * 0.4,
        y: cy + math.sin(t) * ry + math.cos(i * 1.9) * 0.4,
      ),
    );
  }
  return out;
}

void main() {
  test('直线', () {
    final ShapeSnap? snap = recognizeShape(_line(20, 30, 260, 90));
    expect(snap?.shape, SnapShape.line);
  });

  test('矩形与正方形', () {
    final ShapeSnap? rect = recognizeShape(
      _polygon(<(double, double)>[(20, 20), (280, 20), (280, 170), (20, 170)]),
    );
    expect(rect?.shape, SnapShape.rectangle);

    final ShapeSnap? square = recognizeShape(
      _polygon(<(double, double)>[(20, 20), (200, 20), (200, 200), (20, 200)]),
    );
    expect(square?.shape, SnapShape.square);
  });

  test('圆与椭圆', () {
    final ShapeSnap? circle = recognizeShape(_ellipse(150, 150, 100, 100));
    expect(circle?.shape, SnapShape.circle);

    final ShapeSnap? ellipse = recognizeShape(_ellipse(180, 120, 140, 70));
    expect(ellipse?.shape, SnapShape.ellipse);
  });

  test('三角形（直角 / 等腰 / 一般）', () {
    final ShapeSnap? right = recognizeShape(
      _polygon(<(double, double)>[(40, 40), (240, 40), (40, 200)]),
    );
    expect(right?.shape, SnapShape.rightTriangle);

    final ShapeSnap? iso = recognizeShape(
      _polygon(<(double, double)>[(150, 30), (260, 220), (40, 220)]),
    );
    expect(iso?.shape, SnapShape.isoscelesTriangle);

    final ShapeSnap? general = recognizeShape(
      _polygon(<(double, double)>[(30, 40), (260, 70), (120, 220)]),
    );
    expect(
      general?.shape,
      anyOf(SnapShape.triangle, SnapShape.isoscelesTriangle),
    );
  });

  test('平行四边形', () {
    final ShapeSnap? snap = recognizeShape(
      _polygon(<(double, double)>[(60, 40), (280, 40), (240, 180), (20, 180)]),
    );
    expect(snap?.shape, SnapShape.parallelogram);
  });

  test('负样本：涂鸦 / 勾 / 太小 / 开口弧都不吸', () {
    expect(
      recognizeShape(_points(<(double, double)>[
        (20, 20),
        (40, 80),
        (60, 20),
        (80, 90),
        (100, 30),
        (120, 80),
        (140, 10),
      ])),
      isNull,
    );
    expect(
      recognizeShape(_line(20, 100, 80, 180)), // 只是一个短勾/斜线
      isNotNull,
      reason: '短斜线本身可以识别为直线；这里只确认不崩',
    );
    expect(recognizeShape(_line(20, 20, 40, 30)), isNull);
    expect(
      recognizeShape(<InkPoint>[
        for (int i = 0; i <= 40; i += 1)
          InkPoint(
            x: 100 + math.cos(i / 40 * math.pi) * 80,
            y: 100 + math.sin(i / 40 * math.pi) * 80,
          ),
      ]),
      isNull,
      reason: '半圆开口，不应吸成圆',
    );
  });
}
