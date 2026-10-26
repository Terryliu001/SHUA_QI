import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 右侧面板左边缘的**宽度拖拽把手**（2026-10-24 用户要求：可左右拖大，最大 1/2 屏）。
///
/// 为什么不做成"面板内部可拖"：面板里的每一行都要能点、能拖排序，
/// 把整块做成拖拽区会和列表手势打架。只在**左缘的窄条**上接管横向拖动，
/// 其余区域完全不受影响；视觉上只画一条 4dp 的圆角细杆，不抢内容。
///
/// 2026-10-24 第二轮修正（用户第 10 条）：
/// 1. **命中区 16dp → 28dp**：16dp 在平板上"按不准"，稍微偏一点就变成滚动/点击；
/// 2. **改用绝对位移**：以前抛的是每帧的 `delta.dx`，调用方累加后再 clamp——
///    一旦拖过 1/2 上限，宽度被卡住，往回拖要先"抵消掉超出的那段"才动，
///    手感就是"不再跟手"。现在一次拖动只记**起点 x**，每帧抛「起点到现在」的
///    总位移，超限只是暂时夹住，手一反向就立刻跟手。
class PanelResizeHandle extends StatefulWidget {
  const PanelResizeHandle({
    super.key,
    required this.onResizeStart,
    required this.onResize,
    required this.onResizeEnd,
  });

  final VoidCallback onResizeStart;

  /// **自拖动起点以来的总变宽量**（dp，正 = 变宽）。不是每帧增量。
  final ValueChanged<double> onResize;

  final VoidCallback onResizeEnd;

  @override
  State<PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<PanelResizeHandle> {
  bool _active = false;

  /// 按下时的全局 x。（把手在左缘，向右拖 = 变窄。）
  double _startX = 0;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '调整面板宽度',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 水平拖动才接管；竖直方向的滑动仍交给后面的列表/画布。
        onHorizontalDragStart: (DragStartDetails details) {
          _startX = details.globalPosition.dx;
          setState(() => _active = true);
          widget.onResizeStart();
        },
        onHorizontalDragUpdate: (DragUpdateDetails details) =>
            widget.onResize(_startX - details.globalPosition.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _active = false);
          widget.onResizeEnd();
        },
        onHorizontalDragCancel: () {
          setState(() => _active = false);
          widget.onResizeEnd();
        },
        child: Center(
          child: AnimatedContainer(
            duration: ShqMotion.instant,
            width: _active ? 5 : 4,
            height: _active ? 64 : 44,
            decoration: BoxDecoration(
              color: _active ? scheme.primary : scheme.outlineVariant,
              borderRadius: BorderRadius.circular(ShqRadius.pill),
            ),
          ),
        ),
      ),
    );
  }
}
