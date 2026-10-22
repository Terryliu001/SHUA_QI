// T0.2 书写 spike 的数据模型。
//
// 刻意做成独立文件、不依赖任何产品代码：spike 跑完整个目录直接删。
// 坐标一律是**页面坐标（pt，原点左上，y 向下）**，与规格 §5.3 同一口径；
// 像素坐标只在 Listener 里短暂出现，进模型前必须除过 scale。

import 'dart:convert';

/// 一个采样点。
class SpikePoint {
  const SpikePoint({
    required this.x,
    required this.y,
    required this.pressure,
    required this.t,
  });

  factory SpikePoint.fromJson(Map<String, Object?> json) {
    return SpikePoint(
      x: (json['x']! as num).toDouble(),
      y: (json['y']! as num).toDouble(),
      pressure: (json['p']! as num).toDouble(),
      t: (json['t']! as num).toInt(),
    );
  }

  final double x;
  final double y;

  /// 0..1。鼠标/触摸通常恒为 1.0，只有真笔才有真值——这也是 T0.2 要验的一项。
  final double pressure;

  /// 相对 app 启动的毫秒数，取 `PointerEvent.timeStamp`，**不读系统时钟**（避免落笔路径上出现不确定性）。
  final int t;

  Map<String, Object?> toJson() => <String, Object?>{
    'x': x,
    'y': y,
    'p': pressure,
    't': t,
  };
}

/// 笔画样式。spike 只需要一种，留枚举是为了 JSON 结构以后能扩。
enum SpikeStrokeStyle { pen }

/// 一笔。
class SpikeStroke {
  SpikeStroke({
    required this.pageIndex,
    required this.style,
    required this.points,
  });

  factory SpikeStroke.fromJson(Map<String, Object?> json) {
    final List<Object?> rawPoints = json['points']! as List<Object?>;
    return SpikeStroke(
      pageIndex: (json['page']! as num).toInt(),
      style: SpikeStrokeStyle.values[(json['style']! as num).toInt()],
      points: rawPoints
          .map(
            (Object? item) =>
                SpikePoint.fromJson(item! as Map<String, Object?>),
          )
          .toList(growable: false),
    );
  }

  final int pageIndex;
  final SpikeStrokeStyle style;
  final List<SpikePoint> points;

  Map<String, Object?> toJson() => <String, Object?>{
    'page': pageIndex,
    'style': style.index,
    'points': points
        .map((SpikePoint point) => point.toJson())
        .toList(growable: false),
  };
}

/// 整个 spike 文档：几页 + 所有笔画。落盘就是一个 JSON 文件。
class SpikeDoc {
  SpikeDoc({
    required this.pageCount,
    required this.pageWidth,
    required this.pageHeight,
    List<SpikeStroke>? strokes,
  }) : strokes = strokes ?? <SpikeStroke>[];

  /// A4：595 × 842 pt。注意是 pt，不是像素。
  factory SpikeDoc.a4({int pageCount = 5}) {
    return SpikeDoc(pageCount: pageCount, pageWidth: 595, pageHeight: 842);
  }

  factory SpikeDoc.decode(String source) {
    final Map<String, Object?> map = jsonDecode(source) as Map<String, Object?>;
    final List<Object?> rawStrokes = map['strokes']! as List<Object?>;
    return SpikeDoc(
      pageCount: (map['page_count']! as num).toInt(),
      pageWidth: (map['page_width']! as num).toDouble(),
      pageHeight: (map['page_height']! as num).toDouble(),
      strokes: rawStrokes
          .map(
            (Object? item) => SpikeStroke.fromJson(item! as Map<String, Object?>),
          )
          .toList(),
    );
  }

  final int pageCount;
  final double pageWidth;
  final double pageHeight;
  final List<SpikeStroke> strokes;

  int get pointCount {
    int sum = 0;
    for (final SpikeStroke stroke in strokes) {
      sum += stroke.points.length;
    }
    return sum;
  }

  List<SpikeStroke> strokesOnPage(int pageIndex) => strokes
      .where((SpikeStroke stroke) => stroke.pageIndex == pageIndex)
      .toList(growable: false);

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 'spike_ink_v1',
    'page_count': pageCount,
    'page_width': pageWidth,
    'page_height': pageHeight,
    'stroke_count': strokes.length,
    'point_count': pointCount,
    'strokes': strokes
        .map((SpikeStroke stroke) => stroke.toJson())
        .toList(growable: false),
  };

  String encode({bool pretty = false}) {
    if (pretty) {
      return const JsonEncoder.withIndent('  ').convert(toJson());
    }
    return jsonEncode(toJson());
  }
}
