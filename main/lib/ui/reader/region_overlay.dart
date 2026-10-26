import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/region_set.dart';
import 'package:shuaqi/domain/region/confidence.dart';
import 'package:shuaqi/domain/region/edited_question.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/ui/region/region_action.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 一个题目框的**屏显形态**（页面坐标 pt + 判题分级预留 + 题号 + 身份）。
///
/// [grade] 目前**不参与画框**：三色是判题结果（对 / 存疑 / 错）的语义色，
/// 切题阶段所有自动框统一用中性色。判题上线后可以直接按 [grade] 换色。
///
/// 刻意不直接用 [QuestionBundle]：painter 只需要"画一个框要什么"，
/// 让它认识数据库模型会把 UI 绑在表结构上。
class RegionMark {
  const RegionMark({
    required this.key,
    required this.pageIndex,
    required this.rect,
    required this.label,
    required this.grade,
    required this.confidence,
    this.level = 2,
    this.locked = false,
    this.userAdded = false,
    this.isAnswer = false,
  });

  /// 与覆盖层同一套 anchor key（见 `domain/region/edited_question.dart`）。
  final String key;

  final int pageIndex;

  /// 页面坐标 pt。
  final RegionRect rect;

  final String label;

  /// `green` / `yellow` / `red`。
  final String grade;

  final double confidence;

  /// 1 = 大题（虚线框），2 = 小题。
  final int level;

  final bool locked;

  /// 用户手画的框：用主色画，一眼看出"这是我加的"。
  final bool userAdded;

  /// 作答框：紫色虚线，和题目框是两套语义。
  final bool isAnswer;

  RegionMark withRect(RegionRect value) => RegionMark(
    key: key,
    pageIndex: pageIndex,
    rect: value,
    label: label,
    grade: grade,
    confidence: confidence,
    level: level,
    locked: locked,
    userAdded: userAdded,
    isAnswer: isAnswer,
  );
}

/// 把切题结果摊平成"框列表"。跨页题在每页各算一个框。
List<RegionMark> regionMarksOf(RegionSet set) {
  final List<RegionMark> marks = <RegionMark>[];
  for (final QuestionBundle bundle in set.questions) {
    final Question question = bundle.question;
    if (bundle.slices.isEmpty) {
      continue;
    }
    final String grade = RegionGrade.of(question.confidence).name;
    final String key = bundle.anchorKey;
    for (final QuestionSlice slice in bundle.slices) {
      marks.add(
        RegionMark(
          key: key,
          pageIndex: slice.pageIndex,
          rect: slice.rect,
          label: question.label ?? '${question.ordinal}',
          grade: grade,
          confidence: question.confidence,
          level: question.level,
          locked: bundle.locked,
          userAdded: question.source == 'manual',
        ),
      );
    }
  }
  return marks;
}

/// 叠加层的编辑配置。null = 只读（缩略图、导出预览这类场景）。
class RegionOverlayConfig {
  const RegionOverlayConfig({
    this.editable = false,
    this.selectedKey,
    this.onSelect,
    this.onDeselect,
    this.onMove,
    this.onResize,
    this.onMenu,
    this.actionsOf,
    this.onAction,
    this.answerEditing = false,
  });

  final bool editable;
  final String? selectedKey;
  final ValueChanged<String>? onSelect;

  /// 再点一下已选中的框 = 取消选中。
  final VoidCallback? onDeselect;

  final RegionMoveCallback? onMove;
  final RegionResizeCallback? onResize;
  final void Function(String key, Offset globalPosition)? onMenu;

  /// 这道题此刻可用的显式操作（切分/并入/跨页/锁定/删除）。
  final Set<RegionAction> Function(RegionMark mark)? actionsOf;

  /// 浮动条上点了某个操作。
  final void Function(String key, RegionAction action)? onAction;

  /// 作答框编辑模式：为 true 时**所有作答框**都吃指针，点一下就能选中/拖动。
  ///
  /// 作答框默认与题目框重合，两者不能同时全量可点（会永远选中上层那个）。
  /// 所以做成互斥模式：面板的「显示作答情况」打开 = 编辑作答框，
  /// 关闭 = 编辑题目框。
  final bool answerEditing;
}

/// 拖动整框（拖动结束才回调，一次拖动 = 一步撤销）。
typedef RegionMoveCallback = void Function(
  String key,
  int pageIndex,
  double dx,
  double dy,
);

/// 缩放（拖动结束才回调）。
typedef RegionResizeCallback = void Function(
  String key,
  int pageIndex,
  RegionRect rect,
);

/// 题目区域叠加层：三色框 + 题号胶囊 + 贴框操作条 +（编辑态）拖动/缩放。
///
/// ## 两态模型（2026-10-23 重做，旧方案已废弃）
///
/// | 态 | 进入方式 | 框的表现 |
/// |---|---|---|
/// | **只读态** | 默认（面板关） | 只画。整层不吃任何指针——写字、滚动、缩放全都穿透 |
/// | **编辑态** | 打开「题目区域」面板 | 画布被父层锁住；框内任意位置可点选，选中后可拖 |
///
/// ## 2026-10-23 第二次重做（用户反馈）
///
/// 1. **形态**：整框改成 2px 粗描边 + 14px 大圆角（搜题软件的常见语言）。
///    未选中时**不再画四个小圆点**——那是"调试标记"，不是界面；
///    圆点只在选中后以圆角手柄出现。
/// 2. **点中能操作**：选中后框的左上角贴出一条浮动操作条（题号 + 切开/并入/跨页/
///    锁定/删除），不必再靠长按去发现功能。
/// 3. **再点取消**：点一下已选中的框就取消选中（浮动条随之收起）。
///
/// ## 为什么拖动不每帧落库
/// 拖动只改本 widget 里的 `_preview`（一个矩形），每帧只重画这一层；
/// **抬手才回调**父层 → 落一条操作 → 重算 → 新 marks 进来。
class RegionOverlay extends StatefulWidget {
  const RegionOverlay({
    super.key,
    required this.marks,
    required this.pageIndex,
    required this.pageWidthPt,
    required this.pageHeightPt,
    required this.width,
    this.darkPaper = false,
    this.editable = false,
    this.selectedKey,
    this.onSelect,
    this.onDeselect,
    this.onMove,
    this.onResize,
    this.onMenu,
    this.actionsOf,
    this.onAction,
    this.answerEditing = false,
  });

  /// 本页的框（父层已按页过滤）。
  final List<RegionMark> marks;
  final int pageIndex;
  final double pageWidthPt;
  final double pageHeightPt;

  /// 叠放区域的逻辑宽度。
  final double width;

  final bool darkPaper;

  /// true = 可点选/拖动/缩放（对应「题目区域」面板打开）。
  final bool editable;

  final String? selectedKey;
  final ValueChanged<String>? onSelect;
  final VoidCallback? onDeselect;
  final RegionMoveCallback? onMove;
  final RegionResizeCallback? onResize;

  /// 作答框编辑模式：所有作答框都可点选/拖动。
  final bool answerEditing;

  /// 长按框体：由父层弹菜单（与浮动条同一批动作）。
  final void Function(String key, Offset globalPosition)? onMenu;

  final Set<RegionAction> Function(RegionMark mark)? actionsOf;
  final void Function(String key, RegionAction action)? onAction;

  @override
  State<RegionOverlay> createState() => _RegionOverlayState();
}

class _RegionOverlayState extends State<RegionOverlay> {
  /// 拖动中的临时矩形（只影响这一层，不改数据）。
  String? _previewKey;
  RegionRect? _previewRect;
  RegionRect? _dragOrigin;

  /// 预览对应的题号与页。拖动会改 anchor key（key 含 y），
  /// 所以父层回来的新 mark 很可能**不是同一个 key**；靠"题号 + 页 + rect"认。
  String? _previewLabel;
  int? _previewPage;

  /// 抬手后到"父层重算完并把新 rect 送回来"之间，**保留预览**。
  ///
  /// 旧实现抬手立刻清预览：框先弹回原位，等整卷重算（保存 + 切题 + 写库）
  /// 回来再跳到新位置——真机看到就是"移动时跳闪"。
  bool _commitPending = false;
  Timer? _commitSafety;

  double get _scale => widget.width / widget.pageWidthPt;

  double get _pageHeightLogical =>
      widget.width * widget.pageHeightPt / widget.pageWidthPt;

  @override
  void didUpdateWidget(covariant RegionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_commitPending) {
      if (widget.selectedKey == null && oldWidget.selectedKey != null) {
        _clearPreview();
      }
      return;
    }
    final String? key = _previewKey;
    final RegionRect? preview = _previewRect;
    if (key == null || preview == null) {
      return;
    }
    // 父层把新 rect 送回来了（或这道题已经不在）：预览使命结束。
    //
    // 注意 key 里含 y，拖动/改大小后 key 会变；所以先认精确 key，再退到
    // "同题号 + 同页 + rect 已经和预览一致"。
    RegionMark? exact;
    RegionMark? landed;
    for (final RegionMark mark in widget.marks) {
      if (mark.key == key) {
        exact = mark;
      }
      if (mark.label == _previewLabel &&
          mark.pageIndex == _previewPage &&
          _rectClose(mark.rect, preview)) {
        landed = mark;
      }
    }
    if (exact != null && _rectClose(exact.rect, preview)) {
      _clearPreview();
      return;
    }
    if (landed != null) {
      _clearPreview();
      return;
    }
    // 旧 key 已经消失、且这一层的数据确实换了：说明父层已经重算过，
    // 直接显示权威 rect（可能被页边距夹过），不要一直挂着旧预览。
    if (exact == null && !_sameMarks(oldWidget.marks, widget.marks)) {
      _clearPreview();
    }
  }

  static bool _sameMarks(List<RegionMark> a, List<RegionMark> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key ||
          a[i].rect != b[i].rect ||
          a[i].isAnswer != b[i].isAnswer) {
        return false;
      }
    }
    return true;
  }

  static bool _rectClose(RegionRect a, RegionRect b) =>
      (a.left - b.left).abs() <= 1 &&
      (a.top - b.top).abs() <= 1 &&
      (a.width - b.width).abs() <= 1 &&
      (a.height - b.height).abs() <= 1;

  @override
  void dispose() {
    _commitSafety?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.marks.isEmpty || widget.pageWidthPt <= 0 || widget.width <= 0) {
      return const SizedBox.shrink();
    }
    final List<RegionMark> drawn = <RegionMark>[
      for (final RegionMark mark in widget.marks)
        if (_previewKey == mark.key && _previewRect != null)
          mark.withRect(_previewRect!)
        else
          mark,
    ];
    RegionMark? selected;
    for (final RegionMark mark in drawn) {
      if (mark.key == widget.selectedKey) {
        selected = mark;
        break;
      }
    }
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _RegionPainter(
                  marks: drawn,
                  scale: _scale,
                  darkPaper: widget.darkPaper,
                  selectedKey: widget.selectedKey,
                ),
              ),
            ),
          ),
        ),
        // 空白处点一下 = 取消选中（2026-10-23 用户口径：有选中态时，点未选中的
        // 空白区理应回到未选中）。它放在框的**下层**：点框仍然选中框，
        // 点空白才落到这一层；只挂 tap，不参与拖动/滚动，滚动手势照常赢。
        // `opaque`：调框模式下不再把指针漏给下面的墨迹层，手写笔不会同时落笔。
        if (widget.editable)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onDeselect?.call(),
            ),
          ),
        if (widget.editable) ..._buildInteraction(drawn),
        if (widget.editable && selected != null) ..._buildActionBar(selected),
      ],
    );
  }

  /// 编辑态的命中层：**整个框**可点选/拖动，四角与四边中点是缩放把手。
  ///
  /// 顺序很重要：先放整块（底层），再放手柄，最后放操作条——
  /// 后加的子节点在 Stack 里命中优先级更高，否则拖角会变成"移动整框"、
  /// 点浮动条会变成"选中框"。
  List<Widget> _buildInteraction(List<RegionMark> marks) {
    final List<Widget> widgets = <Widget>[];
    for (final RegionMark mark in marks) {
      final Rect rect = _toScreen(mark.rect);
      if (rect.isEmpty) {
        continue;
      }
      final bool selected = widget.selectedKey == mark.key;
      // 作答框只在"作答框编辑模式"或被选中时吃指针：默认它和题目框重合，
      // 若整块可命中，点题目框会永远选中作答框，题目框就再也改不了。
      if (mark.isAnswer && !selected && !widget.answerEditing) {
        continue;
      }
      // **点中才可拖**：未选中时只挂 tap（滚动会赢掉 tap，所以运动时不误触）；
      // 选中之后才挂 pan：此时用户就是在调这个框，吃掉拖动是对的。
      //
      // 2026-10-26 用户第 18 条：**锁定的框不给拖动**（可点选、可解锁，
      // 但拖不动、也拉不了把手）——否则"锁定"只是个摆设。
      final bool draggable = selected && !mark.locked;
      widgets.add(
        Positioned(
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onTap: () {
              if (selected) {
                widget.onDeselect?.call();
              } else {
                widget.onSelect?.call(mark.key);
              }
            },
            onLongPressStart: (LongPressStartDetails details) =>
                widget.onMenu?.call(mark.key, details.globalPosition),
            onPanStart: draggable
                ? (DragStartDetails details) => _startDrag(mark)
                : null,
            onPanUpdate: draggable
                ? (DragUpdateDetails details) => _updateMove(details.delta)
                : null,
            onPanEnd: draggable
                ? (DragEndDetails details) => _commitMove()
                : null,
          ),
        ),
      );
      // 把手只在选中后出现（未选中时整框的粗圆角就是"这块能点"的提示）。
      // 锁定的框**不出现把手**：它现在不能改。
      if (!selected || mark.locked) {
        continue;
      }
      for (final _Handle handle in _Handle.values) {
        final Offset center = _handlePosition(rect, handle);
        final bool corner = _Handle.corners.contains(handle);
        final double hit = corner
            ? ShqRegion.handleHit
            : ShqRegion.edgeHandleHit;
        widgets.add(
          Positioned(
            left: center.dx - hit / 2,
            top: center.dy - hit / 2,
            width: hit,
            height: hit,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onPanStart: (DragStartDetails details) => _startDrag(mark),
              onPanUpdate: (DragUpdateDetails details) =>
                  _updateResize(handle, details.delta),
              onPanEnd: (DragEndDetails details) => _commitResize(),
            ),
          ),
        );
      }
    }
    return widgets;
  }

  /// 贴框的操作条：优先放框下方，放不下翻上方，都放不下贴框内侧。
  List<Widget> _buildActionBar(RegionMark mark) {
    // 作答框（紫色虚线）不挂动作条：它的调节走面板里的「答题情况」。
    if (mark.isAnswer) {
      return const <Widget>[];
    }
    final Set<RegionAction> available =
        widget.actionsOf?.call(mark) ?? const <RegionAction>{};
    // 题目框的浮条只放三个高频动作（其余在面板/长按里），
    // 且**只画此刻真能做的**：第一题没有"并入上题"，就不出现那个按钮。
    final Set<RegionAction> barActions = <RegionAction>{
      RegionAction.merge,
      RegionAction.rename,
      RegionAction.delete,
    }.intersection(available);
    if (barActions.isEmpty) {
      return const <Widget>[];
    }
    final Rect rect = _toScreen(mark.rect);
    if (rect.isEmpty) {
      return const <Widget>[];
    }
    final double barWidth = _ActionBar.widthFor(mark.label, barActions);
    const double barHeight = _ActionBar.height;
    final double pageHeight = _pageHeightLogical;
    const double gap = 8;
    const double margin = 4;

    double top = rect.bottom + gap;
    if (top + barHeight > pageHeight - margin) {
      top = rect.top - gap - barHeight;
    }
    if (top < margin) {
      top = (rect.bottom - barHeight - gap).clamp(
        margin,
        math.max(margin, pageHeight - barHeight - margin),
      );
    }
    double left = rect.left;
    left = left.clamp(
      margin,
      math.max(margin, widget.width - barWidth - margin),
    );

    return <Widget>[
      Positioned(
        left: left,
        top: top,
        width: barWidth,
        height: barHeight,
        child: _ActionBar(
          label: mark.label,
          actions: barActions,
          onAction: (RegionAction action) =>
              widget.onAction?.call(mark.key, action),
        ),
      ),
    ];
  }

  void _startDrag(RegionMark mark) {
    widget.onSelect?.call(mark.key);
    _commitSafety?.cancel();
    _commitPending = false;
    // 上一次拖动还没被父层确认时，从**屏幕上看到的**位置继续，别从旧数据起跳。
    _dragOrigin = _previewKey == mark.key && _previewRect != null
        ? _previewRect!
        : mark.rect;
    _previewKey = mark.key;
    _previewLabel = mark.label;
    _previewPage = mark.pageIndex;
    _previewRect = _dragOrigin;
  }

  void _updateMove(Offset delta) {
    final RegionRect? origin = _dragOrigin;
    if (origin == null) {
      return;
    }
    final RegionRect current = _previewRect ?? origin;
    setState(() {
      _previewRect = clampRect(
        RegionRect(
          left: current.left + delta.dx / _scale,
          top: current.top + delta.dy / _scale,
          width: origin.width,
          height: origin.height,
        ),
        pageWidth: widget.pageWidthPt,
        pageHeight: widget.pageHeightPt,
      );
    });
  }

  void _commitMove() {
    final RegionRect? origin = _dragOrigin;
    final RegionRect? preview = _previewRect;
    final String? key = _previewKey;
    if (origin == null || preview == null || key == null) {
      _clearPreview();
      return;
    }
    final double dx = preview.left - origin.left;
    final double dy = preview.top - origin.top;
    // 位移 < 2pt 当点选，不制造一条空操作（否则撤销要按两下）。
    if (dx.abs() < 2 && dy.abs() < 2) {
      _clearPreview();
      return;
    }
    // **先不清预览**：等父层重算回来、rect 与预览一致再清（见 _commitPending）。
    _commitPending = true;
    _commitSafety?.cancel();
    _commitSafety = Timer(const Duration(milliseconds: 1500), _clearPreview);
    widget.onMove?.call(key, widget.pageIndex, dx, dy);
  }

  void _updateResize(_Handle handle, Offset delta) {
    final RegionRect? origin = _dragOrigin;
    if (origin == null) {
      return;
    }
    final double dx = delta.dx / _scale;
    final double dy = delta.dy / _scale;
    final RegionRect current = _previewRect ?? origin;
    double left = current.left;
    double top = current.top;
    double right = current.right;
    double bottom = current.bottom;
    switch (handle) {
      case _Handle.topLeft:
        left += dx;
        top += dy;
      case _Handle.topRight:
        right += dx;
        top += dy;
      case _Handle.bottomLeft:
        left += dx;
        bottom += dy;
      case _Handle.bottomRight:
        right += dx;
        bottom += dy;
      case _Handle.top:
        top += dy;
      case _Handle.bottom:
        bottom += dy;
      case _Handle.left:
        left += dx;
      case _Handle.right:
        right += dx;
    }
    // 最小 24pt：再小就没法再拖回来（把手会挤在一起）。
    if (right - left < 24) {
      if (handle == _Handle.left ||
          handle == _Handle.topLeft ||
          handle == _Handle.bottomLeft) {
        left = right - 24;
      } else {
        right = left + 24;
      }
    }
    if (bottom - top < 24) {
      if (handle == _Handle.top ||
          handle == _Handle.topLeft ||
          handle == _Handle.topRight) {
        top = bottom - 24;
      } else {
        bottom = top + 24;
      }
    }
    setState(() {
      _previewRect = clampRect(
        RegionRect.fromLTRB(left, top, right, bottom),
        pageWidth: widget.pageWidthPt,
        pageHeight: widget.pageHeightPt,
        minSize: 24,
      );
    });
  }

  void _commitResize() {
    final RegionRect? preview = _previewRect;
    final RegionRect? origin = _dragOrigin;
    final String? key = _previewKey;
    if (preview == null || origin == null || key == null || preview == origin) {
      _clearPreview();
      return;
    }
    _commitPending = true;
    _commitSafety?.cancel();
    _commitSafety = Timer(const Duration(milliseconds: 1500), _clearPreview);
    widget.onResize?.call(key, widget.pageIndex, preview);
  }

  void _clearPreview() {
    _commitSafety?.cancel();
    _commitSafety = null;
    _commitPending = false;
    if (_previewKey == null && _previewRect == null) {
      return;
    }
    setState(() {
      _previewKey = null;
      _previewRect = null;
      _dragOrigin = null;
      _previewLabel = null;
      _previewPage = null;
    });
  }

  Rect _toScreen(RegionRect rect) => Rect.fromLTWH(
    rect.left * _scale,
    rect.top * _scale,
    rect.width * _scale,
    rect.height * _scale,
  );

  Offset _handlePosition(Rect rect, _Handle handle) => switch (handle) {
    _Handle.topLeft => rect.topLeft,
    _Handle.topRight => rect.topRight,
    _Handle.bottomLeft => rect.bottomLeft,
    _Handle.bottomRight => rect.bottomRight,
    _Handle.top => Offset(rect.center.dx, rect.top),
    _Handle.bottom => Offset(rect.center.dx, rect.bottom),
    _Handle.left => Offset(rect.left, rect.center.dy),
    _Handle.right => Offset(rect.right, rect.center.dy),
  };
}

enum _Handle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  top,
  bottom,
  left,
  right;

  static const List<_Handle> corners = <_Handle>[
    topLeft,
    topRight,
    bottomLeft,
    bottomRight,
  ];
}

class _RegionPainter extends CustomPainter {
  _RegionPainter({
    required this.marks,
    required this.scale,
    required this.darkPaper,
    required this.selectedKey,
  });

  final List<RegionMark> marks;
  final double scale;
  final bool darkPaper;
  final String? selectedKey;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint fill = Paint()..style = PaintingStyle.fill;
    final Paint stroke = Paint()..style = PaintingStyle.stroke;

    for (final RegionMark mark in marks) {
      final Rect raw = Rect.fromLTWH(
        mark.rect.left * scale,
        mark.rect.top * scale,
        mark.rect.width * scale,
        mark.rect.height * scale,
      );
      final Rect rect = raw.intersect(Offset.zero & size);
      if (rect.isEmpty) {
        continue;
      }
      final bool selected = mark.key == selectedKey;
      final Color color = _colorOf(mark);
      final double radius = math.min(
        ShqRegion.radius,
        math.min(rect.width, rect.height) / 2 - 0.5,
      );
      final RRect rounded = RRect.fromRectAndRadius(
        rect.deflate(ShqRegion.strokeSelected / 2),
        Radius.circular(math.max(1, radius)),
      );
      fill.color = color.withValues(
        alpha: selected ? ShqRegion.fillAlphaSelected : ShqRegion.fillAlpha,
      );
      stroke
        ..color = color.withValues(alpha: selected ? 1 : 0.78)
        ..strokeWidth = selected
            ? ShqRegion.strokeSelected
            : ShqRegion.strokeWidth;
      canvas.drawRRect(rounded, fill);
      if (mark.level == 1 || mark.isAnswer) {
        _drawDashed(canvas, rounded, stroke);
      } else {
        canvas.drawRRect(rounded, stroke);
      }
      _drawLabel(canvas, rect, mark, color);
      // 选中态**只加粗描边**：不画手柄（2026-10-23 用户拍板）。
      // 理由：手柄是编辑器的语言，而这里是"读卷子"的场景——四个方块会盖住题面、
      // 也和卷面上的圈号/句号混淆。选中这件事，一条更粗更实的圆角边已经说清楚了。
    }
  }

  Color _colorOf(RegionMark mark) {
    if (mark.isAnswer) {
      return darkPaper ? ShqRegion.answerOnDark : ShqRegion.answer;
    }
    // 用户 2026-10-24：手改框不再单独用主色，所有题目框统一中性色。
    // "是不是手画"由面板里的文字信息表达，不靠颜色制造第二套语义。
    return darkPaper ? ShqRegion.autoOnDark : ShqRegion.auto;
  }

  /// 大题用虚线框：一眼区分"这是容器"和"这是真题目"。
  void _drawDashed(Canvas canvas, RRect rrect, Paint paint) {
    final Path path = Path()..addRRect(rrect);
    for (final PathMetric metric in path.computeMetrics()) {
      double distance = 0;
      const double dash = 7;
      const double gap = 5;
      while (distance < metric.length) {
        final double end = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  /// 题号胶囊：贴在框内左上角。固定字号（不随缩放变大）——
  /// 它是界面标注，不是卷面内容，放大卷子时不该跟着变巨。
  void _drawLabel(Canvas canvas, Rect rect, RegionMark mark, Color color) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: mark.locked ? '${mark.label} 锁' : mark.label,
        style: TextStyle(
          fontSize: ShqRegion.labelSize,
          height: 1.1,
          fontWeight: FontWeight.w600,
          color: darkPaper ? const Color(0xFF191612) : Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(28, rect.width - 18));
    final double chipWidth = painter.width + 12;
    const double chipHeight = ShqRegion.labelHeight;
    final double left = rect.left + 5;
    final double chipTop = math.min(
      rect.top + 5,
      math.max(rect.top + 1, rect.bottom - chipHeight - 2),
    );
    final RRect chip = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, chipTop, chipWidth, chipHeight),
      const Radius.circular(ShqRegion.labelRadius),
    );
    canvas.drawRRect(chip, Paint()..color = color.withValues(alpha: 0.94));
    painter.paint(
      canvas,
      Offset(left + 6, chipTop + (chipHeight - painter.height) / 2),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(_RegionPainter oldDelegate) {
    return oldDelegate.scale != scale ||
        oldDelegate.darkPaper != darkPaper ||
        oldDelegate.selectedKey != selectedKey ||
        oldDelegate.marks.length != marks.length ||
        !_sameMarks(oldDelegate.marks, marks);
  }

  static bool _sameMarks(List<RegionMark> a, List<RegionMark> b) {
    for (int i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key ||
          a[i].rect != b[i].rect ||
          a[i].grade != b[i].grade ||
          a[i].label != b[i].label ||
          a[i].locked != b[i].locked ||
          a[i].isAnswer != b[i].isAnswer ||
          a[i].userAdded != b[i].userAdded) {
        return false;
      }
    }
    return true;
  }
}

/// 贴框浮动条（2026-10-23 用户第二轮反馈后）：**题号（可改）+ 并入上题 + 删除**。
///
/// 设计约束：
/// - 它贴着题面，**越短越好**——多余的动作用长按菜单（那里空间不受限，还能带解释）。
/// - 题号本身就是按钮：点它就能改（扫描件认不出数字，用户手填是刚需）。
/// - "并入上题"是扫描件含解析/答案步骤时最常用的修复动作（把 `(1)(2)` 并回题干），
///   所以必须一键可达，不能只藏在长按菜单里。
/// - 不可用时**灰掉而不是藏起来**（第一题没有"上题"）。
/// - 删除用错误色，放在最右，破坏性操作离手最远。
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.label,
    required this.actions,
    required this.onAction,
  });

  static const double height = 34;
  static const double buttonSize = 30;

  /// 按钮顺序：与面板/长按菜单同一套（同一个功能不在不同入口换位置）。
  static const List<RegionAction> order = <RegionAction>[
    RegionAction.split,
    RegionAction.merge,
    RegionAction.extend,
    RegionAction.lock,
    RegionAction.rename,
    RegionAction.addQuestion,
    RegionAction.delete,
  ];

  final String label;

  /// 这条浮条上有哪些动作。**只画传进来的**：
  /// 题目框传 merge/rename/delete，作答框传 addQuestion（2026-10-25）。
  final Set<RegionAction> actions;
  final ValueChanged<RegionAction> onAction;

  static double labelWidth(String text) =>
      (text.length * 8.0 + 14).clamp(30, 82).toDouble();

  /// 整条宽度（与 [build] 的排布公式一一对应，定位夹取要用同一个数）。
  ///
  /// `6` 而不是 `4`：`Container` 的 `Border.all` 会再占 1px×2，少算就会
  /// 在真机上出现"RIGHT OVERFLOWED BY 2.0 PIXELS"的黄黑条（2026-10-23 真机）。
  static double widthFor(String label, Set<RegionAction> actions) {
    final int buttons = order.where(actions.contains).length;
    return 6 + labelWidth(label) + 10 + buttons * (1 + buttonSize);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool canRename = actions.contains(RegionAction.rename);
    final List<RegionAction> buttons = order
        .where(actions.contains)
        .toList(growable: false);
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(ShqRadius.pill),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            InkWell(
              onTap: canRename
                  ? () => onAction(RegionAction.rename)
                  : null,
              borderRadius: BorderRadius.circular(ShqRadius.pill),
              child: SizedBox(
                width: labelWidth(label) + 10,
                height: height,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (canRename) ...<Widget>[
                      const SizedBox(width: 3),
                      Icon(
                        Icons.edit_outlined,
                        size: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            for (final RegionAction action in buttons) ...<Widget>[
              Container(width: 1, height: 14, color: scheme.outlineVariant),
              _BarButton(
                icon: regionActionIcon(action, locked: false),
                tooltip: action.menuLabel,
                destructive: action.destructive,
                onTap: () => onAction(action),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 不再有"禁用态"：浮条只画这道题此刻真能做的动作（不可用的根本不出现），
    // 灰掉的按钮既解释不清也点不动。
    final Color color = destructive ? scheme.error : scheme.onSurface;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: _ActionBar.buttonSize,
          height: _ActionBar.buttonSize,
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }
}
