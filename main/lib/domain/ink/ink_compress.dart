import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 笔迹点压缩（纯 Dart，可单测）。
///
/// 为什么需要：触控笔采样率 200Hz+，一划就是几百个点，多数点间距小于
/// 一个像素的几分之一——全存下来 SIF 体积翻几倍，Path 顶点翻几倍，
/// 而肉眼与识别都看不出差别。T0.2 spike 实测 0.35pt 间距过滤后
/// 笔画形态无可见变化。
///
/// 语义（流式，配合落笔路径）：
/// 1. 每个点先过 [add]：与上一个**保留点**距离 < [minDistancePt] 就丢弃；
/// 2. 抬笔时调 [finish]：如果原始末点与最后一个保留点有可感知距离，
///    强制补回末点——否则"写到一半停住"的那一笔结尾会短一截。
/// 3. 单点笔画（点一下）保留该点：它是一个"点"，不是可以丢的噪声。
class InkCompressor {
  InkCompressor({this.minDistancePt = kDefaultMinDistancePt});

  /// 默认最小间距（pt）。T0.2 spike 实测值：低于它过滤无可见变化。
  static const double kDefaultMinDistancePt = 0.35;

  final double minDistancePt;

  final List<InkPoint> _kept = <InkPoint>[];

  double get _minDistanceSq => minDistancePt * minDistancePt;

  /// 已保留的点（过程可见，供 UI 直接绘制）。
  List<InkPoint> get points => List<InkPoint>.unmodifiable(_kept);

  bool get isEmpty => _kept.isEmpty;

  /// 喂入一个原始采样点。返回 true 表示被保留。
  bool add(InkPoint point) {
    if (_kept.isEmpty) {
      _kept.add(point);
      return true;
    }
    final InkPoint last = _kept.last;
    final double dx = point.x - last.x;
    final double dy = point.y - last.y;
    if (dx * dx + dy * dy < _minDistanceSq) {
      return false;
    }
    _kept.add(point);
    return true;
  }

  /// 抬笔：返回最终点列（含强制补回的末点）。
  ///
  /// [finalPoint] 是原始流的最后一个点——它可能刚被 [add] 丢掉
  /// （停笔前最后一下位移通常很小）。这里按 1/4 阈值补回：
  /// 能看见的截断要补，看不见的补了也是噪声。
  List<InkPoint> finish(InkPoint finalPoint) {
    if (_kept.isEmpty) {
      return const <InkPoint>[];
    }
    final InkPoint last = _kept.last;
    final double dx = finalPoint.x - last.x;
    final double dy = finalPoint.y - last.y;
    final double threshold = minDistancePt / 4;
    if (dx * dx + dy * dy > threshold * threshold) {
      _kept.add(finalPoint);
    }
    return List<InkPoint>.unmodifiable(_kept);
  }
}
