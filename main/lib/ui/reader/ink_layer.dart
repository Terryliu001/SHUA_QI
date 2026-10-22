import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/ink/ink_compress.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_width.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:shuaqi/state/ink_providers.dart';
import 'package:shuaqi/ui/reader/ink_painters.dart';
import 'package:shuaqi/ui/reader/ink_ribbon.dart';

/// 一页的墨迹层（T2.1）：三层画布的最上两层 + stylus 输入分流。
///
/// ## 结构（T0.2 spike 验证过的三层画布）
/// ```text
/// PageLayer
///  ├─ RepaintBoundary(PaperEffect 背景位图)  ← 兄弟节点，不是父子！滤镜不染墨迹
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
/// 只有：坐标换算（→ 页面 pt）、[InkCompressor] 过滤、压力归一、
/// ribbon append、`_activeTick` 通知。无 await / IO / setState。
/// 落盘在抬笔后异步走 [InkDocController.commit]（T2.4 之前是内存存储）。
///
/// ## 压感（T2.2 返工，见 `domain/ink/ink_width.dart`）
/// 真机 DOWN 事件的压力常读到 0，抬笔常读到 0/1——**都不能当真值用**，
/// 否则表现就是"起笔发丝、抬笔突然变粗"。这里统一过 [_pressureOf]：
/// 落笔与抬笔用中性压力，中途 0 读数沿用上一个有效值。
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

  /// 当前笔刷（钢笔 / 圆珠笔 / 荧光笔）。只影响**之后**画的笔，已落笔的不变。
  final InkStrokeStyle style;

  /// false 时这一页不接受落笔（分页模式放大中用 touch 平移，不写字）。
  final bool enabled;

  @override
  ConsumerState<InkLayer> createState() => _InkLayerState();
}

class _InkLayerState extends ConsumerState<InkLayer> {
  final ValueNotifier<int> _activeTick = ValueNotifier<int>(0);
  final CommittedInkCache _cache = CommittedInkCache();

  /// 正在写的这一笔的几何。笔刷变了就换一条（笔刷变化不可能发生在笔中途）。
  InkRibbon? _ribbon;

  InkCompressor? _compressor;

  /// 当前这笔最近一次**有效**压力。DOWN / UP 的 0 读数用它兜底。
  double _lastPressure = InkWidth.neutralPressure;

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

  /// 压力归一：把"不可信的读数"换成可用的值。
  ///
  /// - `<= 0.02`：Android 的 DOWN/UP 事件与"笔尖轻触离开"都会报 0。
  ///   落笔时用中性压力（0.5，钢笔取区间中值），中途沿用上一个有效值
  ///   （保住收笔那一小段的粗细，而不是突然收成发丝）。
  /// - `>= 0.999`：无压感设备（鼠标 / 触摸）恒为 1.0，不能当成"按到最重"。
  double _pressureOf(PointerEvent event) {
    final double raw = event.pressure;
    if (raw <= 0.02) {
      return _lastPressure;
    }
    if (raw >= 0.999) {
      return InkWidth.neutralPressure;
    }
    _lastPressure = raw;
    return raw;
  }

  InkRibbon _ribbonFor(InkStrokeStyle style, Color color) {
    final InkRibbon? current = _ribbon;
    if (current == null || current.style != style) {
      final InkRibbon next = InkRibbon(style: style, color: color)
        ..beginStroke();
      _ribbon = next;
      return next;
    }
    return current;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled || _activePointer >= 0 || !_accepts(event.kind)) {
      return;
    }
    _activePointer = event.pointer;
    _compressor = InkCompressor();
    // 落笔：压力基线重置为中性，避免上一笔的重压"传染"到这一笔的起笔。
    _lastPressure = InkWidth.neutralPressure;
    final InkRibbon ribbon = _ribbonFor(widget.style, inkColorOf(context))..clear();
    ribbon.beginStroke();

    final InkPoint first = InkPoint(
      x: _toPagePt(event.localPosition).dx,
      y: _toPagePt(event.localPosition).dy,
      pressure: _pressureOf(event),
      t: event.timeStamp.inMilliseconds,
    );
    _compressor!.add(first);
    ribbon.addPoint(first);
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
      pressure: _pressureOf(event),
      t: event.timeStamp.inMilliseconds,
    );
    if (compressor.add(point)) {
      final InkRibbon? ribbon = _ribbon;
      if (ribbon != null) {
        ribbon.addPoint(point);
        _activeTick.value++;
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_activePointer != event.pointer) {
      return;
    }
    _commit(
      InkPoint(
        x: _toPagePt(event.localPosition).dx,
        y: _toPagePt(event.localPosition).dy,
        pressure: _lastPressure,
        t: event.timeStamp.inMilliseconds,
      ),
    );
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_activePointer != event.pointer) {
      return;
    }
    // 取消事件的坐标不可信：直接用最后一个已保留点收尾（距离 0，不会追加）。
    final InkCompressor? compressor = _compressor;
    if (compressor == null || compressor.isEmpty) {
      _resetActive();
      return;
    }
    _commit(compressor.points.last);
  }

  void _resetActive() {
    _activePointer = -1;
    _compressor = null;
    _lastPressure = InkWidth.neutralPressure;
    _ribbon?.clear();
    _activeTick.value++;
  }

  /// 抬笔：压缩收尾 → 生成 stroke → 异步提交。
  ///
  /// 单点笔画保留（点一下是一个"点"，比如选择题打钩打点）。
  /// 收尾点的压力与时间戳必须取**真实值**：早先这里硬编码 `pressure: 0.5, t: 0`，
  /// 结果每一笔的尾巴都被强行拉成中粗（就是"抬笔粗细突变"的第二个来源）。
  void _commit(InkPoint endPoint) {
    final InkCompressor? compressor = _compressor;
    final InkRibbon? ribbon = _ribbon;
    _activePointer = -1;
    _compressor = null;
    if (compressor == null) {
      _resetActive();
      return;
    }
    final List<InkPoint> points = compressor.finish(endPoint);
    // 活动层与已提交层几何相同：清掉活动层不会闪——下一次 build 里
    // InkDocController.commit 已经把这一笔同步写进 state（同一帧内完成）。
    ribbon?.endStroke();
    ribbon?.clear();
    _activeTick.value++;
    _lastPressure = InkWidth.neutralPressure;
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
    _cache.sync(doc, inkColor: inkColor, highlighterColor: highlighterColorOf);

    final InkRibbon active = _ribbonFor(widget.style, inkColor);
    active.color = inkColor;

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
                highlighterColor: highlighterColorOf,
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: ActiveStrokePainter(
                ribbon: active,
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
