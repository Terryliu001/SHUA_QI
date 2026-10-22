/// 笔迹模型（纯 Dart，无 Flutter、无 IO）。
///
/// 坐标一律是**页面坐标 pt，原点左上，y 向下**（§5.3）。像素坐标不允许进入本层——
/// 所有 `devicePixelRatio` 与缩放换算必须发生在 ui/infra 内部，进模型前就除干净。
///
/// 本文件**不许** import Flutter / dart:ui，也不许 import `dart:io`。
library;

/// 一个采样点。
class InkPoint {
  const InkPoint({
    required this.x,
    required this.y,
    this.pressure = 0.5,
    this.t = 0,
  });

  final double x;
  final double y;

  /// 0..1。无压感设备（鼠标/触摸）由上层统一填 0.5，不许留 0 或 1 冒充真实压感。
  final double pressure;

  /// 相对会话开始的毫秒数（单调递增，不读系统时钟）。
  final int t;
}

/// 轴对齐矩形（pt）。domain 不依赖 dart:ui，所以自己定义，避免为了一个 Rect 引入 Flutter。
class InkRect {
  const InkRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  factory InkRect.fromPoints(List<InkPoint> points) {
    if (points.isEmpty) {
      return const InkRect(left: 0, top: 0, width: 0, height: 0);
    }
    double minX = points.first.x;
    double maxX = points.first.x;
    double minY = points.first.y;
    double maxY = points.first.y;
    for (final InkPoint point in points) {
      if (point.x < minX) {
        minX = point.x;
      }
      if (point.x > maxX) {
        maxX = point.x;
      }
      if (point.y < minY) {
        minY = point.y;
      }
      if (point.y > maxY) {
        maxY = point.y;
      }
    }
    return InkRect(
      left: minX,
      top: minY,
      width: maxX - minX,
      height: maxY - minY,
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

  double get area => width * height;
}

/// 笔刷（T2.2 三种）。
enum InkStrokeStyle {
  /// 钢笔：压感驱动线宽。
  pen,

  /// 圆珠笔：等宽，稍细。
  ballpoint,

  /// 荧光笔：乘算混合，必须垫在文字下方（见 [InkStroke.excludeFromOcr]）。
  highlighter,
}

/// 一笔。
class InkStroke {
  const InkStroke({
    required this.uid,
    required this.points,
    this.style = InkStrokeStyle.pen,
  });

  /// ULID（§5.3）。由调用方生成——domain 不持有 id 生成器，避免隐式随机源。
  final String uid;

  final List<InkPoint> points;
  final InkStrokeStyle style;

  /// 荧光笔永不进入识别（§6.2 规则 6）。
  ///
  /// 做成**计算属性而不是字段**，是为了从类型上消灭"忘记设置这个标志"的可能：
  /// 只要 style 是 highlighter，就一定被排除。
  bool get excludeFromOcr => style == InkStrokeStyle.highlighter;

  InkRect get bounds => InkRect.fromPoints(points);

  int get pointCount => points.length;

  bool get isEmpty => points.isEmpty;
}

/// 一页的笔迹（§7 `InkStore.load` 的返回类型）。
///
/// 不可变：任何修改都返回新实例。这样 `revision` 才有意义（异步回写要拿它做版本校验，INV-02）。
class InkDoc {
  const InkDoc({required this.revision, required this.strokes});

  static const InkDoc empty = InkDoc(revision: 0, strokes: <InkStroke>[]);

  /// 每次落盘 +1。异步任务回写前必须比对，过期即丢弃。
  final int revision;

  final List<InkStroke> strokes;

  bool get isEmpty => strokes.isEmpty;

  int get strokeCount => strokes.length;

  int get pointCount {
    int sum = 0;
    for (final InkStroke stroke in strokes) {
      sum += stroke.pointCount;
    }
    return sum;
  }

  /// 参与识别的笔画（自动剔除荧光笔）。
  List<InkStroke> get recognizableStrokes => strokes
      .where((InkStroke stroke) => !stroke.excludeFromOcr)
      .toList(growable: false);

  InkDoc copyWith({int? revision, List<InkStroke>? strokes}) {
    return InkDoc(
      revision: revision ?? this.revision,
      strokes: strokes ?? this.strokes,
    );
  }

  /// 追加一笔并递增 revision。返回新实例，不改原对象。
  InkDoc append(InkStroke stroke) {
    final List<InkStroke> next = <InkStroke>[...strokes, stroke];
    return InkDoc(revision: revision + 1, strokes: next);
  }

  /// 整体换一批笔画（擦除 / 撤销 / 清空都走它）。递增 revision。
  ///
  /// revision 就是"这一页的笔迹变过几次"，识别（W4）拿它做过期判定，
  /// 所以**任何**改变笔画集合的操作都必须 +1，包括撤销和重做。
  InkDoc withStrokes(List<InkStroke> next) {
    return InkDoc(revision: revision + 1, strokes: List<InkStroke>.of(next));
  }

  /// 删掉 [uids] 里的笔画（保持其余顺序不变）。空集合时原样返回。
  InkDoc withoutUids(Set<String> uids) {
    if (uids.isEmpty) {
      return this;
    }
    final List<InkStroke> next = strokes
        .where((InkStroke stroke) => !uids.contains(stroke.uid))
        .toList(growable: false);
    if (next.length == strokes.length) {
      return this;
    }
    return withStrokes(next);
  }

  /// 按原索引把 [items] 插回去（撤销删除用）。
  ///
  /// 按**索引升序**逐条插入即可还原原始 z 序：每次插入后，
  /// 后续条目记录的原索引仍然指向它该在的位置（标准做法，见单测）。
  InkDoc insertAll(List<({int index, InkStroke stroke})> items) {
    if (items.isEmpty) {
      return this;
    }
    final List<({int index, InkStroke stroke})> sorted =
        List<({int index, InkStroke stroke})>.of(items)
          ..sort(
            (({int index, InkStroke stroke}) a, ({int index, InkStroke stroke}) b) =>
                a.index.compareTo(b.index),
          );
    final List<InkStroke> next = List<InkStroke>.of(strokes);
    for (final ({int index, InkStroke stroke}) item in sorted) {
      final int at = item.index.clamp(0, next.length);
      next.insert(at, item.stroke);
    }
    return withStrokes(next);
  }

  /// 某笔画的下标；不存在返回 -1。
  int indexOfUid(String uid) {
    for (int i = 0; i < strokes.length; i++) {
      if (strokes[i].uid == uid) {
        return i;
      }
    }
    return -1;
  }
}
