import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/ink/ink_compress.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:shuaqi/state/ink_providers.dart';
import 'package:shuaqi/ui/reader/ink_painters.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 一页的墨迹层（T2.1）：三层画布的最上两层 + stylus 输入分流。
///
/// ## 结构（T0.2 spike 验证过的三层画布）
/// ```text
/// PageLayer
///  ├─ PaperEffect(背景位图)      ← 兄弟节点，不是父子！滤镜不染墨迹
///  └─ InkLayer（本 widget）
///      ├─ ClipRect              ← 墨迹不越页界（数据不裁剪，只裁显示）
///      ├─ CustomPaint(committed) ← 只在抬笔重绘
///      └─ CustomPaint(active)    ← 每帧只重绘这一层（ValueNotifier 驱动）
/// ```
///
/// ## 输入分流（规格 §6.9.1：笔写、指滚）
/// 只收 `stylus` / `invertedStylus`；touch 一律穿透到父层手势
/// （滚动模式平移/缩放、分页模式缩放/双击）。**同一时刻只受理一个指针**：
/// 手掌或第二根手指落上来也不会插进当前这笔（T0.2 实测过的"缝合线"事故）。
///
/// ## 落笔路径（INV-01）
/// 只有：坐标换算（→ 页面 pt）、[InkCompressor] 过滤、点追加、
/// `_activeTick` 通知。无 await / IO / setState。落盘在抬笔后异步走
/// [InkDocController.commit]（T2.4 之前是内存存储）。
class InkLayer extends ConsumerStatefulWidget {
  const InkLayer({
    super.key,
    required this.inkKey,
    required this.pageWidthPt,
    required this.width,
    this.style = InkStrokeStyle.pen,
    this.enabled = true,
  });

  /// (sessionId, pageIndex) —— 笔迹的定位。
  final InkPageKey inkKey;

  /// 页面尺寸（pt）与显示宽度（逻辑像素）。换算：`pt = local × pageWidthPt / width`。
  final double pageWidthPt;
  final double width;

  /// 笔刷（T2.2 才有选择 UI，先固定钢笔）。
  final InkStrokeStyle style;

  /// false 时这一页不接受落笔（分页模式放大中用 touch 平移，不写字）。
  final bool enabled;

  @override
  ConsumerState<InkLayer> createState() => _InkLayerState();
}

class _InkLayerState extends ConsumerState<InkLayer> {
  final List<InkPoint> _activePoints = <InkPoint>[];
  final ValueNotifier<int> _activeTick = ValueNotifier<int>(0);
  final CommittedInkCache _cache = CommittedInkCache();

  InkCompressor? _compressor;

  /// 当前这笔的 pointer id；-1 表示没在写。
  int _activePointer = -1;

  double get _scale =>
      widget.pageWidthPt > 0 ? widget.width / widget.pageWidthPt : 1;

  @override
  void dispose() {
    _activeTick.dispose();
    super.dispose();
  }

  // ── 输入分流 ───────────────────────────────────────────────────────

  bool _accepts(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  Offset _toPagePt(Offset local) {
    final double scale = _scale;
    return Offset(local.dx / scale, local.dy / scale);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled || _activePointer >= 0 || !_accepts(event.kind)) {
      return;
    }
    _activePointer = event.pointer;
    _compressor = InkCompressor();
    final InkPoint first = InkPoint(
      x: _toPagePt(event.localPosition).dx,
      y: _toPagePt(event.localPosition).dy,
      pressure: event.pressure,
      t: event.timeStamp.inMilliseconds,
    );
    _compressor!.add(first);
    _activePoints
      ..clear()
      ..add(first);
    _activeTick.value++;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_activePointer != event.pointer || !_accepts(event.kind)) {
      return;
    }
    final InkCompressor? compressor = _compressor;
    if (compressor == null) {
      return;
    }
    final InkPoint point = InkPoint(
      x: _toPagePt(event.localPosition).dx,
      y: _toPagePt(event.localPosition).dy,
      pressure: event.pressure,
      t: event.timeStamp.inMilliseconds,
    );
    if (compressor.add(point)) {
      _activePoints.add(point);
      _activeTick.value++;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_activePointer != event.pointer) {
      return;
    }
    _commit(event.localPosition);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_activePointer != event.pointer) {
      return;
    }
    _commit(event.localPosition);
  }

  /// 抬笔：压缩收尾 → 生成 stroke → 异步提交。
  ///
  /// 单点笔画保留（点一下是一个"点"，比如选择题打钩打点）——
  /// 与 spike"少于 2 点就丢"不同，那是 spike 的简化。
  void _commit(Offset lastLocal) {
    final InkCompressor? compressor = _compressor;
    _activePointer = -1;
    _compressor = null;
    _activePoints.clear();
    _activeTick.value++;
    if (compressor == null) {
      return;
    }
    final List<InkPoint> points = compressor.finish(
      InkPoint(
        x: _toPagePt(lastLocal).dx,
        y: _toPagePt(lastLocal).dy,
        pressure: 0.5,
        t: 0,
      ),
    );
    if (points.isEmpty) {
      return;
    }
    unawaited(
      ref
          .read(inkDocProvider(widget.inkKey).notifier)
          .commit(
            InkStroke(uid: Ulid.next(), points: points, style: widget.style),
          ),
    );
  }

  // ── 渲染 ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final InkDoc doc = ref.watch(inkDocProvider(widget.inkKey));
    final Color inkColor = inkColorOf(context);
    final double scale = _scale;

    // 新笔画到了才同步缓存（InkDoc 不可变，append 产生新实例）
    _cache.sync(doc);

    return ClipRect(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(
              painter: CommittedInkPainter(
                cache: _cache,
                doc: doc,
                scale: scale,
                inkColor: inkColor,
                highlighterColor: ShqPalette.highlighter,
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: ActiveStrokePainter(
                points: _activePoints,
                style: widget.style,
                scale: scale,
                color: inkColor,
                repaint: _activeTick,
              ),
            ),
          ),
          // 输入层铺满整页：translucent 让 touch 继续穿透到父层手势
          // （滚动平移/缩放、分页缩放），stylus 由本层消费。
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
            ),
          ),
        ],
      ),
    );
  }
}
