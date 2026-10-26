import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/records/records_stats.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 科目/题型词云（自绘，不引第三方包）。
///
/// ## 为什么自绘
/// 白名单里没有词云库；而"按权重排字 + 不重叠"本质上是几十行几何，
/// 引一个包反而多一份无法审计的布局黑箱（还常带一次性随机种子，每次刷新都跳）。
///
/// ## 三个确定性约束
/// 1. **排序确定**：`buildCloudWords` 已按权重/题数/名字排好，同数据两次绘制完全一样；
/// 2. **布局确定**：阿基米德螺旋 + 固定角度步长，没有 `Random`；
/// 3. **放不下就缩小/丢弃**：先缩 15% 再试，仍不行就跳过——绝不叠字。
///
/// 只画不响应点击：词云是"结构概览"，点一个词跳转到哪里都会是猜的
/// （科目对应书架文件夹，题型没有对应页面）。宁可不可点，也不做假按钮。
class RecordsWordCloud extends StatelessWidget {
  const RecordsWordCloud({
    super.key,
    required this.words,
    this.height = 172,
    this.emptyLabel = '还没有可归纳的科目',
  });

  final List<CloudWord> words;
  final double height;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    if (words.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            emptyLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = Size(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          final _CloudLayout layout = _layoutFor(
            size: size,
            words: words,
            low: scheme.onSurfaceVariant,
            high: scheme.primary,
            textScaler: MediaQuery.textScalerOf(context),
          );
          return CustomPaint(painter: _CloudPainter(layout));
        },
      ),
    );
  }
}

class _PlacedWord {
  const _PlacedWord(this.painter, this.offset);

  final TextPainter painter;
  final Offset offset;
}

class _CloudLayout {
  const _CloudLayout(this.words);

  final List<_PlacedWord> words;

  void dispose() {
    for (final _PlacedWord word in words) {
      word.painter.dispose();
    }
  }
}

/// 最多同时放这么多个词：再多字会小到看不清，词云就退化成噪点。
const int _kMaxWords = 22;

/// 布局缓存（尺寸/数据变了才重排）。上限 3 份，避免旋转/切页时堆积。
final Map<String, _CloudLayout> _layoutCache = <String, _CloudLayout>{};

_CloudLayout _layoutFor({
  required Size size,
  required List<CloudWord> words,
  required Color low,
  required Color high,
  required TextScaler textScaler,
}) {
  final List<CloudWord> top = words.take(_kMaxWords).toList(growable: false);
  final String signature =
      '${size.width.round()}x${size.height.round()}'
      '|${textScaler.scale(10).toStringAsFixed(2)}'
      '|${low.toARGB32()}|${high.toARGB32()}'
      '|${top.map((CloudWord w) => '${w.label}:${w.weight}').join(',')}';
  final _CloudLayout? cached = _layoutCache[signature];
  if (cached != null) {
    return cached;
  }

  final double maxWeight = top.isEmpty ? 0 : top.first.weight;
  final List<_PlacedWord> placed = <_PlacedWord>[];
  final List<Rect> taken = <Rect>[];
  final Offset center = Offset(size.width / 2, size.height / 2);

  for (final CloudWord word in top) {
    double font = cloudFontSize(
      word.weight,
      maxWeight: maxWeight,
      min: 11,
      max: math.min(30, size.height / 4.2),
    );
    for (int attempt = 0; attempt < 3; attempt += 1) {
      final double t = maxWeight <= 0
          ? 0
          : math.sqrt((word.weight / maxWeight).clamp(0.0, 1.0));
      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: word.label,
          style: TextStyle(
            fontSize: font,
            height: 1.06,
            letterSpacing: ShqType.letterSpacingLabel * 0.5,
            fontWeight: t > 0.72 ? FontWeight.w600 : FontWeight.w500,
            color: Color.lerp(low, high, 0.25 + 0.75 * t),
          ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();

      final Offset? spot = _findSpot(
        size: size,
        center: center,
        wordSize: Size(painter.width, painter.height),
        taken: taken,
      );
      if (spot != null) {
        final Rect rect = Rect.fromLTWH(
          spot.dx,
          spot.dy,
          painter.width,
          painter.height,
        );
        placed.add(_PlacedWord(painter, spot));
        taken.add(rect.inflate(2.5));
        break;
      }
      painter.dispose();
      font *= 0.85;
      if (font < 10) {
        break;
      }
    }
  }

  final _CloudLayout layout = _CloudLayout(placed);
  if (_layoutCache.length >= 3) {
    final String firstKey = _layoutCache.keys.first;
    _layoutCache.remove(firstKey)?.dispose();
  }
  _layoutCache[signature] = layout;
  return layout;
}

/// 从中心向外的阿基米德螺旋找一个不重叠的位置。找不到返回 null。
Offset? _findSpot({
  required Size size,
  required Offset center,
  required Size wordSize,
  required List<Rect> taken,
}) {
  const double step = 0.32;
  for (int i = 0; i < 900; i += 1) {
    final double angle = i * step;
    final double radius = 1.35 * math.sqrt(i) * 1.9;
    final Offset raw = Offset(
      center.dx + math.cos(angle) * radius * 1.55 - wordSize.width / 2,
      center.dy + math.sin(angle) * radius - wordSize.height / 2,
    );
    final double x = raw.dx.clamp(0, math.max(0, size.width - wordSize.width));
    final double y = raw.dy.clamp(0, math.max(0, size.height - wordSize.height));
    if (x != raw.dx || y != raw.dy) {
      // 越界后夹紧会产生大量"贴边堆叠"，直接跳过这一圈。
      if (radius > size.shortestSide) {
        break;
      }
      continue;
    }
    final Rect rect = Rect.fromLTWH(x, y, wordSize.width, wordSize.height);
    bool clash = false;
    for (final Rect other in taken) {
      if (rect.overlaps(other)) {
        clash = true;
        break;
      }
    }
    if (!clash) {
      return Offset(x, y);
    }
  }
  return null;
}

class _CloudPainter extends CustomPainter {
  const _CloudPainter(this.layout);

  final _CloudLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    for (final _PlacedWord word in layout.words) {
      word.painter.paint(canvas, word.offset);
    }
  }

  @override
  bool shouldRepaint(_CloudPainter old) => !identical(old.layout, layout);
}
