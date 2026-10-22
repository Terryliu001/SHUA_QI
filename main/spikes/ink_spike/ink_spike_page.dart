import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'frame_stats.dart';
import 'ink_painters.dart';
import 'page_ink_store.dart';
import 'spike_store.dart';
import 'stroke_model.dart';

/// T0.2 书写 spike —— 只验证一件事：在这块屏幕上，Flutter 能不能写到"像纸"。
///
/// 刻意不做的事：不接 pdfrx、不落数据库、不做撤销、不管手掌防误触的复杂逻辑。
///
/// 落笔路径（INV-01）这里只有三样东西：坐标变换、点追加、脏标记。
/// 没有任何 await、IO、JSON、setState。落盘发生在"抬笔 2 秒后"的 Timer 里。
class InkSpikePage extends StatefulWidget {
  const InkSpikePage({super.key});

  @override
  State<InkSpikePage> createState() => _InkSpikePageState();
}

class _InkSpikePageState extends State<InkSpikePage> {
  static const int _pageCount = 5;
  static const int _questionsPerPage = 6;

  /// 采样点最小间距（pt）。低于它直接丢弃，避免高频采样把 Path 顶点撑爆。
  static const double _minSegmentPt = 0.35;

  late final SpikeDoc _doc;
  late final List<PageInkStore> _stores;
  late final List<ui.Picture> _pictures;

  final List<SpikePoint> _activePoints = <SpikePoint>[];
  final ValueNotifier<int> _activeTick = ValueNotifier<int>(0);
  final ValueNotifier<int> _committedTick = ValueNotifier<int>(0);
  final ValueNotifier<int> _hudTick = ValueNotifier<int>(0);

  final FrameStats _stats = FrameStats();
  final SpikeStore _store = SpikeStore();
  final Stopwatch _session = Stopwatch();

  Timer? _hudTimer;
  Timer? _saveDebounce;
  bool _drawing = false;
  bool _allowNonStylus = false;

  /// 当前正在书写的那根手指/笔的 pointer id。
  ///
  /// **为什么必须有它**：`Listener` 会收到屏幕上所有指针的事件。若不按 id 过滤，
  /// 手掌或第二根手指的点会插进同一笔中间，画面上就是一条从笔尖飞到手掌的直线。
  /// 2026-10-22 在平板上实测：开关「非笔输入」后确实出现过这种"缝合线"的风险。
  /// 产品化（T2.1）还要再叠一层：非笔输入一律不落笔（手掌防误触）。
  int _activePointer = -1;

  double _scale = 1;
  int _pageIndex = 0;
  int _lastHudBumpMs = 0;
  int _restoredStrokes = 0;
  String _saveStatus = '未落盘';
  String? _savePath;

  /// 最近一次被接受的指针类型（stylus / invertedStylus / touch / mouse）。
  /// 显示在 HUD 上，用来一眼确认"只收笔"的判定是否真的生效。
  String _lastInputKind = '—';

  @override
  void initState() {
    super.initState();
    _doc = SpikeDoc.a4(pageCount: _pageCount);
    _stores = List<PageInkStore>.generate(
      _pageCount,
      (int index) => PageInkStore(),
    );
    _pictures = List<ui.Picture>.generate(
      _pageCount,
      (int index) => buildFakeExamPage(
        pageIndex: index,
        pageWidth: _doc.pageWidth,
        pageHeight: _doc.pageHeight,
        questionCount: _questionsPerPage,
      ),
    );
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _hudTimer = Timer.periodic(
      const Duration(seconds: 1),
      (Timer timer) => _hudTick.value++,
    );
    unawaited(_restore());
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _hudTimer?.cancel();
    _saveDebounce?.cancel();
    _activeTick.dispose();
    _committedTick.dispose();
    _hudTick.dispose();
    super.dispose();
  }

  // ── 帧耗时 ────────────────────────────────────────────────────────────────

  void _onTimings(List<FrameTiming> timings) {
    _stats.addTimings(timings);
    // HUD 节流到 4Hz：它自己若每帧 setState，测出来的数字就是自己造成的。
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastHudBumpMs < 250) {
      return;
    }
    _lastHudBumpMs = now;
    _hudTick.value++;
  }

  // ── 落笔路径：只有坐标变换 + 点追加 + 脏标记 ──────────────────────────────

  bool _accepts(PointerDeviceKind kind) {
    if (kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus) {
      return true;
    }
    // 模拟器只有鼠标/触摸；这是 spike 专用开关，产品代码里不允许存在。
    return _allowNonStylus;
  }

  Offset _toPagePoint(Offset localPx) {
    final double scale = _scale <= 0 ? 1 : _scale;
    return Offset(localPx.dx / scale, localPx.dy / scale);
  }

  void _onPointerDown(PointerDownEvent event) {
    // 已经在写了：后来的指针（第二根手指、手掌）一律忽略，直到当前这笔抬起。
    if (_drawing || !_accepts(event.kind)) {
      return;
    }
    _activePointer = event.pointer;
    _lastInputKind = event.kind.name;
    final Offset point = _toPagePoint(event.localPosition);
    _activePoints
      ..clear()
      ..add(
        SpikePoint(
          x: point.dx,
          y: point.dy,
          pressure: event.pressure,
          t: event.timeStamp.inMilliseconds,
        ),
      );
    _drawing = true;
    if (!_session.isRunning) {
      _session.start();
    }
    _activeTick.value++;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_drawing ||
        event.pointer != _activePointer ||
        !_accepts(event.kind) ||
        _activePoints.isEmpty) {
      return;
    }
    final Offset point = _toPagePoint(event.localPosition);
    final SpikePoint last = _activePoints.last;
    final double dx = point.dx - last.x;
    final double dy = point.dy - last.y;
    if (dx * dx + dy * dy < _minSegmentPt * _minSegmentPt) {
      return;
    }
    _activePoints.add(
      SpikePoint(
        x: point.dx,
        y: point.dy,
        pressure: event.pressure,
        t: event.timeStamp.inMilliseconds,
      ),
    );
    _activeTick.value++;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_drawing || event.pointer != _activePointer) {
      return;
    }
    _commitActiveStroke();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (!_drawing || event.pointer != _activePointer) {
      return;
    }
    _commitActiveStroke();
  }

  void _commitActiveStroke() {
    _drawing = false;
    _activePointer = -1;
    if (_activePoints.length < 2) {
      _activePoints.clear();
      _activeTick.value++;
      return;
    }
    final SpikeStroke stroke = SpikeStroke(
      pageIndex: _pageIndex,
      style: SpikeStrokeStyle.pen,
      points: List<SpikePoint>.unmodifiable(_activePoints),
    );
    _doc.strokes.add(stroke);
    _stores[_pageIndex].appendStroke(stroke);
    _activePoints.clear();
    _activeTick.value++;
    _committedTick.value++;
    _scheduleSave();
  }

  // ── 落盘：抬笔 2 秒后，串行写入；不进落笔路径 ─────────────────────────────

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () {
      unawaited(_persist(_doc));
    });
  }

  Future<void> _persist(SpikeDoc doc) async {
    try {
      final String path = await _store.save(doc.encode());
      _saveStatus = '已落盘 ${doc.strokes.length} 笔';
      _savePath = path;
    } on Object catch (error) {
      _saveStatus = '落盘失败：$error';
    }
    _hudTick.value++;
  }

  Future<void> _restore() async {
    final String? raw = await _store.load();
    if (raw == null || !mounted) {
      return;
    }
    try {
      final SpikeDoc loaded = SpikeDoc.decode(raw);
      setState(() {
        _doc.strokes
          ..clear()
          ..addAll(loaded.strokes);
        for (final PageInkStore store in _stores) {
          store.clear();
        }
        for (final SpikeStroke stroke in loaded.strokes) {
          if (stroke.pageIndex >= 0 && stroke.pageIndex < _stores.length) {
            _stores[stroke.pageIndex].appendStroke(stroke);
          }
        }
        _restoredStrokes = loaded.strokes.length;
      });
      _activeTick.value++;
      _committedTick.value++;
    } on Object {
      // 文件损坏就当没写过：spike 不为此做任何修复逻辑。
    }
  }

  // ── 按钮 ─────────────────────────────────────────────────────────────────

  void _toggleTimer() {
    setState(() {
      if (_session.isRunning) {
        _session.stop();
      } else {
        _session.start();
      }
    });
  }

  void _goToPage(int next) {
    if (next < 0 || next >= _pageCount) {
      return;
    }
    setState(() {
      _pageIndex = next;
    });
    _activeTick.value++;
    _committedTick.value++;
  }

  Future<void> _export() async {
    await _persist(_doc);
    if (!mounted) {
      return;
    }
    final String path = _savePath ?? '（落盘失败，见 HUD）';
    _toast('已导出 ${_doc.strokes.length} 笔 / ${_doc.pointCount} 点\n$path');
  }

  Future<void> _clear() async {
    setState(() {
      _doc.strokes.clear();
      for (final PageInkStore store in _stores) {
        store.clear();
      }
      _activePoints.clear();
      _restoredStrokes = 0;
      _session
        ..stop()
        ..reset();
    });
    _activeTick.value++;
    _committedTick.value++;
    _stats.reset();
    await _store.clear();
    if (mounted) {
      _toast('已清空（含落盘文件）');
    }
  }

  void _resetStats() {
    _stats.reset();
    _hudTick.value++;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('T0.2 书写 spike'),
        actions: <Widget>[
          Row(
            children: <Widget>[
              const Text('非笔输入', style: TextStyle(fontSize: 12)),
              Switch(
                value: _allowNonStylus,
                onChanged: (bool value) {
                  setState(() {
                    _allowNonStylus = value;
                  });
                },
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _buildHud(),
          const Divider(height: 1),
          Expanded(child: _buildCanvas()),
          const Divider(height: 1),
          _buildControls(),
        ],
      ),
    );
  }

  Widget _buildHud() {
    return ValueListenableBuilder<int>(
      valueListenable: _hudTick,
      builder: (BuildContext context, int tick, Widget? child) {
        final PageInkStore page = _stores[_pageIndex];
        final double estimateKb = _doc.pointCount * 40 / 1024;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: <Widget>[
              _metric('build', '${_stats.medianBuildMs.toStringAsFixed(1)}ms'),
              _metric('raster', '${_stats.medianRasterMs.toStringAsFixed(1)}ms'),
              _metric('抖动率', '${(_stats.jankRatio * 100).toStringAsFixed(1)}%'),
              _metric('帧', '${_stats.totalFrames}'),
              _metric('页笔画', '${page.strokeCount}'),
              _metric('页点数', '${page.pointCount}'),
              _metric('总点数', '${_doc.pointCount}'),
              _metric('估算内存', '${estimateKb.toStringAsFixed(0)}KB'),
              _metric('页码', '${_pageIndex + 1}/$_pageCount'),
              _metric('计时', _formatDuration(_session.elapsed)),
              _metric('输入', _lastInputKind),
              _metric('落盘', _saveStatus),
              if (_restoredStrokes > 0) _metric('已恢复', '$_restoredStrokes 笔'),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCanvas() {
    return Center(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double scale = math.min(
            constraints.maxWidth / _doc.pageWidth,
            constraints.maxHeight / _doc.pageHeight,
          );
          _scale = scale;
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: SizedBox.fromSize(
              size: Size(_doc.pageWidth * scale, _doc.pageHeight * scale),
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: FakePagePainter(
                          picture: _pictures[_pageIndex],
                          scale: scale,
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: CommittedInkPainter(
                          store: _stores[_pageIndex],
                          scale: scale,
                          repaint: _committedTick,
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: ActiveStrokePainter(
                        points: _activePoints,
                        scale: scale,
                        repaint: _activeTick,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildControls() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonal(
                  onPressed: _toggleTimer,
                  child: Text(_session.isRunning ? '暂停计时' : '开始计时'),
                ),
                OutlinedButton(
                  onPressed: () => _goToPage(_pageIndex - 1),
                  child: const Text('上一页'),
                ),
                OutlinedButton(
                  onPressed: () => _goToPage(_pageIndex + 1),
                  child: const Text('下一页'),
                ),
                OutlinedButton(
                  onPressed: () => unawaited(_export()),
                  child: const Text('导出 JSON'),
                ),
                OutlinedButton(
                  onPressed: () => unawaited(_clear()),
                  child: const Text('清空'),
                ),
                OutlinedButton(
                  onPressed: _resetStats,
                  child: const Text('复位帧统计'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '视觉延迟 App 内测不了：用手机 120fps 录像，数「笔尖接触屏幕」到「像素出现」的帧差 ÷120，重复 5 次取中位。'
              '当前帧数字来自引擎 FrameTiming，debug 模式偏大，只有 profile/release 可作验收依据。',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label $value',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  static String _formatDuration(Duration duration) {
    final String minutes = duration.inMinutes.toString().padLeft(2, '0');
    final String seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
