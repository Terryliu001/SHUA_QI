import 'dart:ui';

/// 采集 Flutter 自报的帧耗时（build + raster），供 spike 的 HUD 显示。
///
/// 为什么用 `FrameTiming` 而不是自己掐表：自己掐的是"我发起了绘制"到"我回到下一行代码"，
/// 那根本不包含光栅化和上屏。`FrameTiming` 是引擎给的权威值，t0.2 的验收数字只能用它。
///
/// 注意：debug 模式下这些数字偏大且失真；只有 profile / release 才有参考价值。
class FrameStats {
  static const int _window = 60;
  static const double _frameBudgetMs = 16667 / 1000;

  final List<double> _buildMs = <double>[];
  final List<double> _rasterMs = <double>[];

  int _totalFrames = 0;
  int _jankyFrames = 0;
  double _worstMs = 0;

  void addTimings(List<FrameTiming> timings) {
    for (final FrameTiming timing in timings) {
      final double build = timing.buildDuration.inMicroseconds / 1000;
      final double raster = timing.rasterDuration.inMicroseconds / 1000;
      _buildMs.add(build);
      _rasterMs.add(raster);
      _totalFrames += 1;
      if (build + raster > _frameBudgetMs) {
        _jankyFrames += 1;
      }
      if (build + raster > _worstMs) {
        _worstMs = build + raster;
      }
    }
    if (_buildMs.length > _window) {
      final int overflow = _buildMs.length - _window;
      _buildMs.removeRange(0, overflow);
      _rasterMs.removeRange(0, overflow);
    }
  }

  int get samples => _buildMs.length;

  int get totalFrames => _totalFrames;

  /// 超过 16.67ms 的帧占比（0..1）。T0.2 真正要看的是它，不是平均值。
  double get jankRatio => _totalFrames == 0 ? 0 : _jankyFrames / _totalFrames;

  double get worstMs => _worstMs;

  double get medianBuildMs => _median(_buildMs);

  double get medianRasterMs => _median(_rasterMs);

  /// 粗略等效帧率：以窗口内 build+raster 中位数反推。
  double get estimatedFps {
    final double ms = medianBuildMs + medianRasterMs;
    if (ms <= 0) {
      return 0;
    }
    return 1000 / ms;
  }

  void reset() {
    _buildMs.clear();
    _rasterMs.clear();
    _totalFrames = 0;
    _jankyFrames = 0;
    _worstMs = 0;
  }

  static double _median(List<double> values) {
    if (values.isEmpty) {
      return 0;
    }
    final List<double> sorted = List<double>.of(values)..sort();
    final int mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) {
      return sorted[mid];
    }
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }
}
