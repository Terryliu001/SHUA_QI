/// 区域几何类型（纯 Dart）。
///
/// 为什么不直接用 `dart:ui` 的 `Rect`：`domain` 层禁止 import Flutter / dart:ui
/// （`test/architecture_test.dart` 强制）。切题的全部几何判断都在本层做，
/// 所以自己定义一个最小的轴对齐矩形，UI 层再转成 `Rect`。
library;

/// 轴对齐矩形，单位 pt，**页面坐标：原点左上、y 向下**。
class RegionRect {
  const RegionRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 由左上与右下两点构造（自动归一，右/下比左/上小时不会产生负尺寸）。
  factory RegionRect.fromLTRB(
    double left,
    double top,
    double right,
    double bottom,
  ) {
    final double l = left < right ? left : right;
    final double t = top < bottom ? top : bottom;
    return RegionRect(
      left: l,
      top: t,
      width: (right - left).abs(),
      height: (bottom - top).abs(),
    );
  }

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;

  double get bottom => top + height;

  double get centerX => left + width / 2;

  double get centerY => top + height / 2;

  bool get isEmpty => width <= 0 || height <= 0;

  bool contains(double x, double y) =>
      x >= left && x <= right && y >= top && y <= bottom;

  /// 与另一矩形是否相交（含边贴边不算）。
  bool intersects(RegionRect other) =>
      left < other.right &&
      right > other.left &&
      top < other.bottom &&
      bottom > other.top;

  /// 与另一矩形的重叠高度（不相交为 0）。
  double overlapHeight(RegionRect other) {
    final double top2 = top > other.top ? top : other.top;
    final double bottom2 = bottom < other.bottom ? bottom : other.bottom;
    return bottom2 > top2 ? bottom2 - top2 : 0;
  }

  /// 包住两者的最小矩形。
  RegionRect union(RegionRect other) => RegionRect.fromLTRB(
    left < other.left ? left : other.left,
    top < other.top ? top : other.top,
    right > other.right ? right : other.right,
    bottom > other.bottom ? bottom : other.bottom,
  );

  /// 四周外扩 [by]（负值内缩，结果不会出现负宽高以外的怪值）。
  RegionRect inflate(double by) =>
      RegionRect.fromLTRB(left - by, top - by, right + by, bottom + by);

  /// 相交部分；不相交返回 [empty]。
  RegionRect intersect(RegionRect other) {
    final double l = left > other.left ? left : other.left;
    final double t = top > other.top ? top : other.top;
    final double r = right < other.right ? right : other.right;
    final double b = bottom < other.bottom ? bottom : other.bottom;
    if (r <= l || b <= t) {
      return empty;
    }
    return RegionRect.fromLTRB(l, t, r, b);
  }

  static const RegionRect empty = RegionRect(
    left: 0,
    top: 0,
    width: 0,
    height: 0,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'x': _r(left),
    'y': _r(top),
    'w': _r(width),
    'h': _r(height),
  };

  factory RegionRect.fromJson(Map<String, Object?> json) => RegionRect(
    left: (json['x']! as num).toDouble(),
    top: (json['y']! as num).toDouble(),
    width: (json['w']! as num).toDouble(),
    height: (json['h']! as num).toDouble(),
  );

  static double _r(double value) => (value * 100).roundToDouble() / 100;

  @override
  String toString() =>
      'RegionRect(${_r(left)}, ${_r(top)} ${_r(width)}×${_r(height)})';

  @override
  bool operator ==(Object other) =>
      other is RegionRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}
