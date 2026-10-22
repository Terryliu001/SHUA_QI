import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/ink/eraser.dart';
import 'package:shuaqi/domain/ink/ink_compress.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';
import 'package:shuaqi/domain/ink/ink_width.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:shuaqi/state/ink_providers.dart';
import 'package:shuaqi/ui/reader/ink_painters.dart';
import 'package:shuaqi/ui/reader/ink_ribbon.dart';

/// 一页的墨迹层（T2.1 三层画布 + T2.3 橡皮）。最上两层 + stylus 输入分流。
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
/// 手掌或第二根手指落上来也不会插进当前这一笔（T0.2 实测过的"缝合线"事故）。
///
/// ## 落笔路径（INV-01）
/// 只有：坐标换算（→ 页面 pt）、[InkCompressor] 过滤、压力归一、
/// ribbon append、`_activeTick` 通知。无 await / IO / setState。
/// 落盘在抬笔后异步走 [InkEditController.commit]（T2.4 之前是内存存储）。
///
/// ## 橡皮（T2.3）
/// **笔画级**橡皮，不做位图擦除（会毁掉矢量结构：导出、识别、SIF 增量都靠它）。
/// 判定在 [Eraser]（纯 Dart + 单测：12pt 阈值、包围盒预筛、段到段距离）。
/// 一次拖动里删掉的笔画在抬笔时合成**一条**撤销命令 —— 用户按一次撤销恢复一划。
/// 笔尾橡皮（`invertedStylus`）直接当橡皮，不用切工具。
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
    required this.inkColor,
    this.tool = InkTool.pen,
    this.enabled = true,
    this.onPenDown,
  });

  /// (sessionId, pageIndex) —— 笔迹的定位。
  final InkPageKey inkKey;

  /// 页面尺寸（pt）与显示宽度（逻辑像素）。换算：`pt = local × pageWidthPt / width`。
  final double pageWidthPt;
  final double width;

  /// 墨色。由纸样式决定（[inkColorFor]）：暗纸用暖白墨，其余用深墨。
  /// **不由 App 主题决定**——笔迹要与它下面的那张纸配对，不是与界面配色配对。
  final Color inkColor;

  /// 当前工具（钢笔 / 圆珠笔 / 荧光笔 / 橡皮）。只影响**之后**落下的笔。
  final InkTool tool;

  /// false 时这一页不接受落笔（例如非当前页）。
  final bool enabled;

  /// 笔落屏时回调一次（**不 await、不 setState**，只用来停惯性滚动）。
  ///
  /// 为什么需要：滚动模式松手后页面还在惯性飘动，此时落笔，字会画在
  /// "还在移动的纸"上——落笔那一刻算出的坐标与落笔后看到的纸已经错开，
  /// 主观就是"放大后写不上"。笔一碰屏就该停：这是纸面 App 的通用手感。
  final VoidCallback? onPenDown;

  @override
  ConsumerState<InkLayer> createState() => _InkLayerState();
}

class _InkLayerState extends ConsumerState<InkLayer> {
  final ValueNotifier<int> _activeTick = ValueNotifier<int>(0);
  final CommittedInkCache _cache = CommittedInkCache();

  /// 正在写的这一笔的几何。笔刷变了就换一条（笔刷变化不可能发生在笔中途）。
  InkRibbon? _ribbon;

  InkCompressor? _compressor;

  /// 当前这笔用的笔刷样式。**与 `widget.tool` 分开存**：
  /// 写到一半切工具（比如点了一下工具栏）不能让这一笔半路换笔刷/变没。
  InkStrokeStyle _activeStyle = InkStrokeStyle.pen;

  /// 当前这笔最近一次**有效**压力。DOWN / UP 的 0 读数用它兜底。
  double _lastPressure = InkWidth.neutralPressure;

  /// 当前这笔的 pointer id；-1 表示没在写。
  int _activePointer = -1;

  /// 这笔是不是橡皮（工具是橡皮，或笔尾倒过来）。
  bool _erasing = false;

  /// 橡皮上一次的位置（用来判断"划过"的那一段）。
  InkPoint? _lastEraseAt;

  /// 当前这笔最近一次收到事件的时刻（毫秒）。
  int _lastActiveEventMs = 0;

  /// 僵死判定阈值：超过这么久没等到 UP / 移动，就认为上一笔的 UP 丢了。
  ///
  /// 为什么必须有这条保护：`_activePointer` 被占着时，后续所有笔都会被
  /// 当成"第二根手指"（手掌）拒掉——**一次丢失的 UP 事件就会让这一页
  /// 永久写不了**，而且没有任何现象提示。真机上偶发丢 UP 是可能的
  /// （系统手势抢占、驱动层抖动），所以必须自愈。
  static const int _stalePointerMs = 1200;

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

  InkPoint _pointOf(PointerEvent event, {double pressure = 0.5}) {
    final Offset pt = _toPagePt(event.localPosition);
    return InkPoint(
      x: pt.dx,
      y: pt.dy,
      pressure: pressure,
      t: event.timeStamp.inMilliseconds,
    );
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
    if (!widget.enabled || !_accepts(event.kind)) {
      return;
    }
    if (_activePointer >= 0) {
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastActiveEventMs < _stalePointerMs) {
        // 真的第二根手指（手掌搭屏）：不打断当前这一笔。
        return;
      }
      // 上一笔僵死（UP 事件丢了）→ 收尾并接管新笔，否则这一页再也写不了。
      _finishActive();
    }
    _activePointer = event.pointer;
    _lastActiveEventMs = DateTime.now().millisecondsSinceEpoch;
    // 落笔即停：惯性/甩动必须立刻停，否则字画在"还在飘的纸"上（也适用于橡皮）。
    widget.onPenDown?.call();

    // 笔尾橡皮（invertedStylus）直接当橡皮：不用切工具，也不用改选中态。
    final bool erase =
        widget.tool.isEraser || event.kind == PointerDeviceKind.invertedStylus;
    if (erase) {
      _beginErase(_pointOf(event));
      return;
    }

    _erasing = false;
    _lastEraseAt = null;
    _activeStyle = widget.tool.strokeStyle ?? InkStrokeStyle.pen;
    _compressor = InkCompressor();
    // 落笔：压力基线重置为中性，避免上一笔的重压"传染"到这一笔的起笔。
    _lastPressure = InkWidth.neutralPressure;
    final InkRibbon ribbon = _ribbonFor(_activeStyle, widget.inkColor)..clear();
    ribbon.beginStroke();

    final InkPoint first = _pointOf(event, pressure: _pressureOf(event));
    _compressor!.add(first);
    ribbon.addPoint(first);
    _activeTick.value++;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_activePointer != event.pointer || !_accepts(event.kind)) {
      return;
    }
    _lastActiveEventMs = DateTime.now().millisecondsSinceEpoch;
    if (_erasing) {
      final InkPoint to = _pointOf(event);
      _eraseAlong(_lastEraseAt, to);
      _lastEraseAt = to;
      return;
    }
    final InkCompressor? compressor = _compressor;
    if (compressor == null) {
      return;
    }
    final InkPoint point = _pointOf(event, pressure: _pressureOf(event));
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
    if (_erasing) {
      _finishActive();
      return;
    }
    _commit(_pointOf(event, pressure: _lastPressure));
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_activePointer != event.pointer) {
      return;
    }
    if (_erasing) {
      // 取消也要把已删的收成一步撤销，否则用户"按撤销却跳到更早的状态"。
      _finishActive();
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

  /// 收掉当前这笔（正常抬笔 / 僵死自愈 / 取消都走这里）。
  void _finishActive() {
    if (_erasing) {
      _erasing = false;
      _lastEraseAt = null;
      _activePointer = -1;
      _lastActiveEventMs = 0;
      ref.read(inkEditProvider(widget.inkKey).notifier).endErase();
      return;
    }
    _resetActive();
  }

  void _resetActive() {
    _activePointer = -1;
    _compressor = null;
    _lastPressure = InkWidth.neutralPressure;
    _ribbon?.clear();
    _activeTick.value++;
  }

  // ── 橡皮 ─────────────────────────────────────────────────────────

  void _beginErase(InkPoint at) {
    // 切到橡皮时把上一笔的活跃几何清掉，避免"残影"。
    _compressor = null;
    _ribbon?.clear();
    _erasing = true;
    _lastEraseAt = at;
    _eraseAlong(null, at);
  }

  /// 擦掉 [from]→[to] 这一划经过的笔画（[from] 为 null = 落笔点一下）。
  void _eraseAlong(InkPoint? from, InkPoint to) {
    final InkDoc doc = ref.read(inkDocProvider(widget.inkKey));
    if (doc.isEmpty) {
      return;
    }
    final List<InkStroke> hit = Eraser.strokesHit(doc.strokes, from, to);
    if (hit.isEmpty) {
      return;
    }
    ref.read(inkEditProvider(widget.inkKey).notifier).eraseStrokes(hit);
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
    final InkStrokeStyle style = _activeStyle;
    _activePointer = -1;
    _compressor = null;
    _lastActiveEventMs = 0;
    if (compressor == null) {
      _resetActive();
      return;
    }
    final List<InkPoint> points = compressor.finish(endPoint);
    // 活动层与已提交层几何相同：清掉活动层不会闪——下一次 build 里
    // InkEditController.commit 已经把这一笔同步写进 state（同一帧内完成）。
    ribbon?.endStroke();
    ribbon?.clear();
    _activeTick.value++;
    _lastPressure = InkWidth.neutralPressure;
    if (points.isEmpty) {
      return;
    }
    unawaited(
      ref
          .read(inkEditProvider(widget.inkKey).notifier)
          .commit(InkStroke(uid: Ulid.next(), points: points, style: style)),
    );
  }

  // ── 渲染 ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final InkDoc doc = ref.watch(inkDocProvider(widget.inkKey));
    final Color inkColor = widget.inkColor;
    final double scale = _scale;

    // 新笔画到了才同步缓存（InkDoc 不可变，append 产生新实例）
    _cache.sync(doc, inkColor: inkColor, highlighterColor: highlighterColorOf);

    // 正在写的那一笔用**它自己的**笔刷（切工具不影响已落下的这一笔）；
    // 没在写时用当前工具（橡皮时画布上没有活跃笔，回落到钢笔只为复用同一条 ribbon）。
    final InkStrokeStyle drawStyle = _activePointer >= 0 && !_erasing
        ? _activeStyle
        : (widget.tool.strokeStyle ?? InkStrokeStyle.pen);
    final InkRibbon active = _ribbonFor(drawStyle, inkColor);
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
