import 'dart:async';
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
/// ## 交互（2026-10-26 用户第 7 条）
/// 词可以在框内拖动：拖动时放大、浮起；松手用一条**弹性回位**动画回到原位。
/// 布局本身是确定性的（同数据同图），拖动只是"临时位移"，不会改变词的位置。
class RecordsWordCloud extends StatefulWidget {
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
  State<RecordsWordCloud> createState() => _RecordsWordCloudState();
}

class _RecordsWordCloudState extends State<RecordsWordCloud>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  /// 当前被拖动的词；null = 没有。
  int? _active;

  /// 正在回位的词与起点。
  int? _settling;
  Offset _settleFrom = Offset.zero;
  Offset _dragOffset = Offset.zero;

  /// 每个词的临时位移（拖动中）；回位动画只影响 [_settling]。
  final Map<int, Offset> _offsets = <int, Offset>{};

  @override
  void didUpdateWidget(covariant RecordsWordCloud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.words != widget.words) {
      _offsets.clear();
      _active = null;
      _settling = null;
      _spring.stop();
    }
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _start(int index) {
    _spring.stop();
    setState(() {
      _active = index;
      _settling = null;
      _dragOffset = _offsets[index] ?? Offset.zero;
    });
  }

  void _update(int index, Offset delta, Size size, _PlacedWord word) {
    final Offset current = _offsets[index] ?? Offset.zero;
    final double width = word.painter.width;
    final double height = word.painter.height;
    // 允许在框内自由拖，但别拖出边界（留 4dp）。
    final double minX = 4 - word.offset.dx;
    final double maxX = size.width - width - 4 - word.offset.dx;
    final double minY = 4 - word.offset.dy;
    final double maxY = size.height - height - 4 - word.offset.dy;
    final Offset next = Offset(
      (current.dx + delta.dx).clamp(
        math.min(minX, maxX),
        math.max(minX, maxX),
      ),
      (current.dy + delta.dy).clamp(
        math.min(minY, maxY),
        math.max(minY, maxY),
      ),
    );
    setState(() {
      _offsets[index] = next;
      _dragOffset = next;
    });
  }

  void _release(int index) {
    final Offset from = _offsets[index] ?? Offset.zero;
    if (from == Offset.zero) {
      setState(() {
        _active = null;
        _offsets.remove(index);
      });
      return;
    }
    setState(() {
      _active = null;
      _settling = index;
      _settleFrom = from;
    });
    unawaited(
      _spring.forward(from: 0).whenComplete(() {
        if (!mounted) {
          return;
        }
        setState(() {
          _settling = null;
          _settleFrom = Offset.zero;
          _offsets.remove(index);
        });
      }),
    );
  }

  Offset _offsetFor(int index) {
    if (_active == index) {
      return _dragOffset;
    }
    if (_settling == index) {
      final double t = Curves.elasticOut.transform(_spring.value);
      return _settleFrom * (1 - t);
    }
    return _offsets[index] ?? Offset.zero;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    if (widget.words.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text(
            widget.emptyLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = Size(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          final _CloudLayout layout = _layoutFor(
            size: size,
            words: widget.words,
            low: scheme.onSurfaceVariant,
            high: scheme.primary,
            textScaler: MediaQuery.textScalerOf(context),
          );
          return AnimatedBuilder(
            animation: _spring,
            builder: (BuildContext context, Widget? child) {
              final List<Offset> offsets = <Offset>[
                for (int i = 0; i < layout.words.length; i += 1)
                  _offsetFor(i),
              ];
              return Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _CloudPainter(
                          layout: layout,
                          offsets: offsets,
                          active: _active,
                          activeScale: _active == null ? 1 : 1.08,
                        ),
                      ),
                    ),
                  ),
                  for (int i = 0; i < layout.words.length; i += 1)
                    Positioned(
                      left: layout.words[i].offset.dx + offsets[i].dx,
                      top: layout.words[i].offset.dy + offsets[i].dy,
                      width: layout.words[i].painter.width,
                      height: layout.words[i].painter.height,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (_) => _start(i),
                        onPanUpdate: (DragUpdateDetails details) => _update(
                          i,
                          details.delta,
                          size,
                          layout.words[i],
                        ),
                        onPanEnd: (_) => _release(i),
                        onPanCancel: () => _release(i),
                      ),
                    ),
                ],
              );
            },
          );
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
  const _CloudPainter({
    required this.layout,
    required this.offsets,
    required this.active,
    required this.activeScale,
  });

  final _CloudLayout layout;
  final List<Offset> offsets;
  final int? active;
  final double activeScale;

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < layout.words.length; i += 1) {
      if (i == active) {
        continue; // 被拖的词最后画，压在最上面。
      }
      _paintWord(canvas, i, scale: 1);
    }
    final int? current = active;
    if (current != null && current < layout.words.length) {
      _paintWord(canvas, current, scale: activeScale);
    }
  }

  void _paintWord(Canvas canvas, int index, {required double scale}) {
    final _PlacedWord word = layout.words[index];
    final Offset offset = offsets[index];
    final Offset at = word.offset + offset;
    if (scale == 1) {
      word.painter.paint(canvas, at);
      return;
    }
    final Offset center = at + Offset(word.painter.width / 2, word.painter.height / 2);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    canvas.translate(-center.dx, -center.dy);
    // 轻微投影，让"拿起来"的感觉更明确。
    word.painter.paint(
      canvas,
      at + const Offset(0, 2),
    );
    word.painter.paint(canvas, at);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CloudPainter old) =>
      !identical(old.layout, layout) ||
      old.active != active ||
      old.activeScale != activeScale ||
      !_sameOffsets(old.offsets, offsets);

  static bool _sameOffsets(List<Offset> a, List<Offset> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
