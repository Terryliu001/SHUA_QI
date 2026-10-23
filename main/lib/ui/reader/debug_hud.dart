import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 性能 HUD 的开关（T2.5）。
///
/// 只在 debug / profile 构建里可用：release 构建里这个 provider 恒为 false，
/// 设置页也不会显示入口 —— 用户不该看到开发期仪表盘。
final NotifierProvider<DebugHudController, bool> debugHudProvider =
    NotifierProvider<DebugHudController, bool>(DebugHudController.new);

class DebugHudController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() {
    if (kReleaseMode) {
      return;
    }
    state = !state;
  }
}

/// 帧耗时采集：`SchedulerBinding.addTimingsCallback` 给的 FrameTiming 是**真实**的
/// 构建时长与光栅化时长（profile 包里有意义，debug 包里数字会偏大，仅作相对比较）。
///
/// 为什么不用 `fps` 一个数：120Hz 屏上"掉到 90fps"听起来还行，但如果每一帧都是
/// 光栅化卡住（raster 11ms > 8.3ms 预算），手感就是"卡卡的"。分开看 build / raster
/// 才知道该优化 widget 树还是优化绘制。
class FrameStats {
  FrameStats({this.capacity = 60});

  static const int budgetMicros60 = 16667;
  static const int budgetMicros120 = 8333;

  final int capacity;
  final ListQueue<int> _build = ListQueue<int>();
  final ListQueue<int> _raster = ListQueue<int>();

  void add(FrameTiming timing) {
    _push(_build, timing.buildDuration.inMicroseconds);
    _push(_raster, timing.rasterDuration.inMicroseconds);
  }

  void _push(ListQueue<int> queue, int value) {
    queue.addLast(value);
    while (queue.length > capacity) {
      queue.removeFirst();
    }
  }

  void clear() {
    _build.clear();
    _raster.clear();
  }

  int get samples => _raster.length;

  int? get buildMedian => _median(_build);

  int? get rasterMedian => _median(_raster);

  int? get rasterWorst => _raster.isEmpty
      ? null
      : _raster.reduce((int a, int b) => a > b ? a : b);

  /// 光栅化超过 60Hz 预算的帧占比（0..1）。这个数比"平均 fps"更能说明"卡不卡"。
  double get rasterOverBudget {
    if (_raster.isEmpty) {
      return 0;
    }
    int over = 0;
    for (final int v in _raster) {
      if (v > budgetMicros60) {
        over++;
      }
    }
    return over / _raster.length;
  }

  static int? _median(ListQueue<int> queue) {
    if (queue.isEmpty) {
      return null;
    }
    final List<int> sorted = queue.toList()..sort();
    return sorted[sorted.length ~/ 2];
  }
}

/// 采集器：挂在阅读器 State 上，随页面销毁。
class FrameStatsCollector {
  FrameStatsCollector() {
    _binding.addTimingsCallback(_onTimings);
  }

  final SchedulerBinding _binding = SchedulerBinding.instance;
  final FrameStats stats = FrameStats();

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming timing in timings) {
      stats.add(timing);
    }
  }

  void dispose() {
    _binding.removeTimingsCallback(_onTimings);
  }
}

/// 开发期性能仪表盘（规格 T2.5：可开关、release 不显示）。
///
/// 显示口径（每一项都有明确来源，避免"看起来像数字"）：
/// - build/raster：最近 60 帧的中位数（μs → ms）；raster 超预算占比更贴手感；
/// - 笔画/点数：当前页（墨迹层真正要画的量）；
/// - 位图缓存：`PageImageCache.usedBytes`，超过预算就会开始互相淘汰；
/// - 上次落盘：T2.4 接入 SIF 后填，现在是"内存存储"。
class DebugHud extends ConsumerStatefulWidget {
  const DebugHud({
    super.key,
    required this.collector,
    required this.doc,
    required this.cache,
  });

  final FrameStatsCollector collector;

  /// 当前页的笔迹（父级 watch provider 得到，笔迹一变就换新实例）。
  final InkDoc doc;

  /// 位图缓存：直接读它，让 500ms 的心跳能拿到**当前**占用（不是父级 build 那一刻的快照）。
  final PageImageCache cache;

  @override
  ConsumerState<DebugHud> createState() => _DebugHudState();
}

class _DebugHudState extends ConsumerState<DebugHud> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 500ms 刷一次：HUD 自己不能成为负担（每帧 setState 会污染被测对象）。
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _ms(int? micros) =>
      micros == null ? '—' : (micros / 1000).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final FrameStats stats = widget.collector.stats;
    final double mb = widget.cache.usedBytes / (1024 * 1024);
    final String over = '${(stats.rasterOverBudget * 100).round()}%';
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: ShqSpace.sm,
          vertical: ShqSpace.xs,
        ),
        decoration: BoxDecoration(
          color: const Color(0xCC000000),
          borderRadius: BorderRadius.circular(ShqRadius.sm),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Color(0xFFB9F6CA),
            fontSize: 11,
            height: 1.35,
            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('build ${_ms(stats.buildMedian)}ms  '
                  'raster ${_ms(stats.rasterMedian)}ms'),
              Text('raster 超 60Hz 预算 $over  最差 '
                  '${_ms(stats.rasterWorst)}ms  n=${stats.samples}'),
              Text('笔画 ${widget.doc.strokeCount}  点 ${widget.doc.pointCount}'),
              Text('位图 ${mb.toStringAsFixed(0)}MB / ${widget.cache.length} 页'),
            ],
          ),
        ),
      ),
    );
  }
}
