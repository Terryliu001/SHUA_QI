import 'package:flutter/material.dart';
import 'package:shuaqi/domain/records/record_time.dart';
import 'package:shuaqi/domain/records/records_stats.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 作答热力图（GitHub 式，26 周 × 7 天）。
///
/// ## 为什么自己画，而不是 182 个 Container
/// 一屏 182 个 widget，每次统计刷新都要重新布局/repaint 一遍；
/// 自绘只有一次 paint，且点击命中用坐标换算（O(1)），滚动时也不掉帧。
///
/// ## 布局口径
/// - **右端对齐本周**（周一起），最后一列就是"本周"，不会截出一个残列；
/// - 未来格子不画（`future`），免得右侧出现一排"永远空着"的方块；
/// - 左侧只标周一/三/五，上方只标"换月"那一列——标签比格子更抢眼，能少则少。
class RecordsHeatmap extends StatelessWidget {
  const RecordsHeatmap({
    super.key,
    required this.weeks,
    required this.today,
    this.selectedDay,
    this.onPick,
  });

  final List<HeatWeek> weeks;
  final DateTime today;
  final DateTime? selectedDay;
  final ValueChanged<DateTime>? onPick;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool dark = theme.brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double labelWidth = 15;
        const double topLabelHeight = 15;
        final int columns = weeks.length;
        // 宽度决定格子大小：2/5 栏（约 460dp）里 26 列 → 10.5dp 左右。
        final double available =
            constraints.maxWidth - labelWidth - ShqHeat.gap * (columns - 1);
        double cell = (available / columns).clamp(5.0, ShqHeat.cell);
        // 52 周在窄栏里放不下（每格只剩 3dp，点不准也看不见）：
        // 这时**不缩格子**，改成横向滚动，格子保持可点的最小尺寸。
        final bool scrollable = cell < kHeatMinCell;
        if (scrollable) {
          cell = kHeatMinCell;
        }
        final double step = cell + ShqHeat.gap;
        final double gridWidth = cell * columns + ShqHeat.gap * (columns - 1);
        final double gridHeight = cell * 7 + ShqHeat.gap * 6;

        final Widget grid = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails details) {
            final ValueChanged<DateTime>? pick = onPick;
            if (pick == null) {
              return;
            }
            final double dx = details.localPosition.dx - labelWidth;
            final double dy = details.localPosition.dy - topLabelHeight;
            if (dx < 0 || dy < 0) {
              return;
            }
            final int column = (dx / step).floor();
            final int row = (dy / step).floor();
            if (column < 0 || column >= weeks.length || row < 0 || row > 6) {
              return;
            }
            // 落在间隙里不算点中（避免"差半个格子也响应"的毛刺感）。
            if (dx - column * step > cell || dy - row * step > cell) {
              return;
            }
            final HeatCell hit = weeks[column].days[row];
            if (hit.future) {
              return;
            }
            pick(hit.day);
          },
          child: CustomPaint(
            size: Size(gridWidth + labelWidth, gridHeight + topLabelHeight),
            painter: _HeatPainter(
              weeks: weeks,
              cell: cell,
              labelWidth: labelWidth,
              topLabelHeight: topLabelHeight,
              empty: theme.colorScheme.surfaceContainerHigh,
              labelColor: theme.colorScheme.onSurfaceVariant,
              selected: theme.colorScheme.primary,
              selectedDay: selectedDay,
              dark: dark,
              textScaler: MediaQuery.textScalerOf(context),
            ),
          ),
        );
        if (!scrollable) {
          return grid;
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          child: grid,
        );
      },
    );
  }
}

/// 格子的最小边长（逻辑 dp）。
///
/// 小于它就点不准了（手指按不准的格子等于没有），所以宁可横向滚动，
/// 也不把格子缩成一条缝。
const double kHeatMinCell = 9;

class _HeatPainter extends CustomPainter {
  _HeatPainter({
    required this.weeks,
    required this.cell,
    required this.labelWidth,
    required this.topLabelHeight,
    required this.empty,
    required this.labelColor,
    required this.selected,
    required this.selectedDay,
    required this.dark,
    required this.textScaler,
  });

  final List<HeatWeek> weeks;
  final double cell;
  final double labelWidth;
  final double topLabelHeight;
  final Color empty;
  final Color labelColor;
  final Color selected;
  final DateTime? selectedDay;
  final bool dark;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final double step = cell + ShqHeat.gap;
    final Paint paint = Paint()..style = PaintingStyle.fill;

    for (int c = 0; c < weeks.length; c += 1) {
      final HeatWeek week = weeks[c];
      for (int r = 0; r < 7; r += 1) {
        final HeatCell day = week.days[r];
        if (day.future) {
          continue;
        }
        final Rect rect = Rect.fromLTWH(
          labelWidth + c * step,
          topLabelHeight + r * step,
          cell,
          cell,
        );
        final Color? fill = ShqHeat.level(day.level, dark: dark);
        paint.color = fill ?? empty;
        canvas.drawRRect(_rounded(rect), paint);
        final DateTime? picked = selectedDay;
        if (picked != null && RecordTime.dayKey(picked) == RecordTime.dayKey(day.day)) {
          canvas.drawRRect(
            _rounded(rect.inflate(1.2)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6
              ..color = selected,
          );
        }
      }
    }

    // 星期标签（只标一/三/五，省空间）。
    for (final int row in <int>[0, 2, 4]) {
      _paintText(
        canvas,
        RecordTime.weekdayNames[row],
        Offset(0, topLabelHeight + row * step - 1),
      );
    }

    // 月份标签：只在"这一列的第一天换了月"时画，且与上一个标签至少隔 20dp。
    double lastLabelRight = -100;
    for (int c = 0; c < weeks.length; c += 1) {
      final DateTime first = weeks[c].firstDay;
      final DateTime prev = c == 0
          ? RecordTime.addDays(first, -7)
          : weeks[c - 1].firstDay;
      if (first.month == prev.month) {
        continue;
      }
      final double x = labelWidth + c * step;
      if (x < lastLabelRight + 20) {
        continue;
      }
      final double width = _paintText(
        canvas,
        '${first.month}月',
        Offset(x, 0),
      );
      lastLabelRight = x + width;
    }
  }

  static RRect _rounded(Rect rect) =>
      RRect.fromRectAndRadius(rect, const Radius.circular(2.5));

  /// 画一行小字，返回宽度（月份标签要用来算下一个标签能不能放下）。
  double _paintText(Canvas canvas, String text, Offset offset) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: labelColor,
          fontSize: 9.5,
          height: 1.1,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    painter.paint(canvas, offset);
    final double width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  bool shouldRepaint(_HeatPainter old) {
    return old.cell != cell ||
        old.empty != empty ||
        old.selectedDay != selectedDay ||
        old.dark != dark ||
        !identical(old.weeks, weeks);
  }
}
