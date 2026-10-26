import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/records/records_stats.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 科目/题型词云（自绘，不引第三方包）。
///
/// ## 交互（2026-10-26 用户第 2 条，重做）
/// 不是"整块词"能拖，而是**每一个字都是独立粒子**：手指按在任意一个字上，
/// 它会跟着走，还会把旁边几个字轻轻推开；松手后所有字用弹性动画回到自己的
/// 原位——字与字重新拼回原来的文件名/科目名，不会散成一地。
///
/// ## 聚合逻辑
/// 每个字有一个 home（由词云布局确定，同一个词的字紧挨着）。
/// 拖动时只改变临时 offset；松手用 `elasticOut` 把所有 offset 归零。
/// 因此"搅动"不会破坏词的可读性，也不会改变下一次布局。
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
    duration: const Duration(milliseconds: 640),
  );

  /// 当前被拖动的字；null = 没有。
  int? _active;

  /// 每个字的临时位移。
  final Map<int, Offset> _offsets = <int, Offset>{};

  /// 松手时所有字从哪里回位。
  Map<int, Offset> _settleFrom = <int, Offset>{};

  @override
  void didUpdateWidget(covariant RecordsWordCloud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.words != widget.words) {
      _offsets.clear();
      _settleFrom.clear();
      _active = null;
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
      _settleFrom = <int, Offset>{};
    });
  }

  /// 在整个词云上做命中：点哪个字就搅哪个字；点空白取最近的字。
  /// 每个字不再各自装 GestureDetector，避免小字命中区太窄/被父层滚动抢走。
  int? _hitGlyph(Offset position, _CloudLayout layout) {
    int? nearest;
    double nearestDistance = 28;
    for (int i = 0; i < layout.glyphs.length; i += 1) {
      final _Glyph glyph = layout.glyphs[i];
      final Offset at = glyph.home + (_offsets[i] ?? Offset.zero);
      final Rect rect = Rect.fromLTWH(
        at.dx,
        at.dy,
        glyph.painter.width,
        glyph.painter.height,
      );
      if (rect.contains(position)) {
        return i;
      }
      final double distance = (rect.center - position).distance;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = i;
      }
    }
    return nearest;
  }

  void _startAt(Offset position, _CloudLayout layout) {
    final int? index = _hitGlyph(position, layout);
    if (index == null) {
      return;
    }
    _start(index);
  }

  void _update(int index, Offset delta, Size size, _CloudLayout layout) {
    final _Glyph glyph = layout.glyphs[index];
    final Offset current = _offsets[index] ?? Offset.zero;
    final Offset next = Offset(
      (current.dx + delta.dx).clamp(
        0.0,
        math.max(0, size.width - glyph.painter.width),
      ),
      (current.dy + delta.dy).clamp(
        0.0,
        math.max(0, size.height - glyph.painter.height),
      ),
    );
    setState(() {
      _offsets[index] = next;
      _scatterAround(index, next, layout);
    });
  }

  /// 搅动：被拖的字经过时，把附近的字轻轻推开，像用手指搅一盘字。
  /// 只是视觉位移，不改变 home；松手后统一回位。
  void _scatterAround(
    int activeIndex,
    Offset activeOffset,
    _CloudLayout layout,
  ) {
    const double radius = 78;
    final _Glyph active = layout.glyphs[activeIndex];
    final Offset activeCenter =
        active.home +
        activeOffset +
        Offset(active.painter.width / 2, active.painter.height / 2);
    for (int i = 0; i < layout.glyphs.length; i += 1) {
      if (i == activeIndex) {
        continue;
      }
      final _Glyph glyph = layout.glyphs[i];
      final Offset homeCenter =
          glyph.home +
          Offset(glyph.painter.width / 2, glyph.painter.height / 2);
      final Offset away = homeCenter - activeCenter;
      final double distance = away.distance;
      if (distance <= 0.01 || distance >= radius) {
        _offsets.remove(i);
        continue;
      }
      final double push = (1 - distance / radius) * 14;
      _offsets[i] = away / distance * push;
    }
  }

  void _release() {
    final int? index = _active;
    if (index == null) {
      return;
    }
    _active = null;
    if (_offsets.isEmpty) {
      setState(() {});
      return;
    }
    _settleFrom = Map<int, Offset>.of(_offsets);
    setState(() {});
    unawaited(
      _spring.forward(from: 0).whenComplete(() {
        if (!mounted) {
          return;
        }
        setState(() {
          _settleFrom = <int, Offset>{};
          _offsets.clear();
        });
      }),
    );
  }

  Offset _offsetFor(int index) {
    if (_settleFrom.isNotEmpty) {
      final double t = Curves.elasticOut.transform(_spring.value);
      return (_settleFrom[index] ?? Offset.zero) * (1 - t);
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
          final Size size = Size(constraints.maxWidth, constraints.maxHeight);
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
                for (int i = 0; i < layout.glyphs.length; i += 1) _offsetFor(i),
              ];
              // 整块词云一个手势识别器：按下的位置命中哪个字就拖哪个字。
              // 比"每个字一个 GestureDetector"稳：小字也有 28px 的最近命中兜底，
              // 也不会因为逐字重建把手势打断。
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (DragStartDetails details) =>
                    _startAt(details.localPosition, layout),
                onPanUpdate: (DragUpdateDetails details) {
                  final int? active = _active;
                  if (active != null) {
                    _update(active, details.delta, size, layout);
                  }
                },
                onPanEnd: (_) => _release(),
                onPanCancel: _release,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    IgnorePointer(
                      child: CustomPaint(
                        painter: _CloudPainter(
                          layout: layout,
                          offsets: offsets,
                          active: _active,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Glyph {
  const _Glyph({required this.painter, required this.home});

  final TextPainter painter;

  /// 字在词里的原始位置；松手回这里，字就重新拼成词。
  final Offset home;

  void dispose() => painter.dispose();
}

class _PlacedWord {
  const _PlacedWord({required this.painter, required this.offset});

  final TextPainter painter;
  final Offset offset;
}

class _CloudLayout {
  const _CloudLayout(this.words, this.glyphs);

  final List<_PlacedWord> words;
  final List<_Glyph> glyphs;

  void dispose() {
    for (final _PlacedWord word in words) {
      word.painter.dispose();
    }
    for (final _Glyph glyph in glyphs) {
      glyph.dispose();
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
  final List<_Glyph> glyphs = <_Glyph>[];
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
      final TextStyle style = TextStyle(
        fontSize: font,
        height: 1.06,
        letterSpacing: ShqType.letterSpacingLabel * 0.5,
        fontWeight: t > 0.72 ? FontWeight.w600 : FontWeight.w500,
        color: Color.lerp(low, high, 0.25 + 0.75 * t),
      );
      final TextPainter painter = TextPainter(
        text: TextSpan(text: word.label, style: style),
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
        placed.add(_PlacedWord(painter: painter, offset: spot));
        taken.add(rect.inflate(2.5));
        _splitGlyphs(
          word: word.label,
          style: style.copyWith(letterSpacing: 0),
          wordRect: rect,
          textScaler: textScaler,
          out: glyphs,
        );
        break;
      }
      painter.dispose();
      font *= 0.85;
      if (font < 10) {
        break;
      }
    }
  }

  final _CloudLayout layout = _CloudLayout(placed, glyphs);
  if (_layoutCache.length >= 3) {
    final String firstKey = _layoutCache.keys.first;
    _layoutCache.remove(firstKey)?.dispose();
  }
  _layoutCache[signature] = layout;
  return layout;
}

/// 把一个词拆成字；每个字的 home 紧挨着，合起来就是原来的词。
void _splitGlyphs({
  required String word,
  required TextStyle style,
  required Rect wordRect,
  required TextScaler textScaler,
  required List<_Glyph> out,
}) {
  final List<TextPainter> painters = <TextPainter>[];
  final List<int> runes = word.runes.toList(growable: false);
  double total = 0;
  for (final int rune in runes) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: String.fromCharCode(rune), style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    painters.add(painter);
    total += painter.width;
  }
  double x = wordRect.left + (wordRect.width - total) / 2;
  final double y =
      wordRect.top +
      (wordRect.height - (painters.isEmpty ? 0 : painters.first.height)) / 2;
  for (int i = 0; i < painters.length; i += 1) {
    out.add(_Glyph(painter: painters[i], home: Offset(x, y)));
    x += painters[i].width;
  }
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
    final double y = raw.dy.clamp(
      0,
      math.max(0, size.height - wordSize.height),
    );
    if (x != raw.dx || y != raw.dy) {
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
  });

  final _CloudLayout layout;
  final List<Offset> offsets;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < layout.glyphs.length; i += 1) {
      if (i == active) {
        continue; // 被拖的字最后画，压在最上面。
      }
      _paintGlyph(canvas, i, scale: 1);
    }
    final int? current = active;
    if (current != null && current < layout.glyphs.length) {
      _paintGlyph(canvas, current, scale: 1.12);
    }
  }

  void _paintGlyph(Canvas canvas, int index, {required double scale}) {
    final _Glyph glyph = layout.glyphs[index];
    final Offset offset = offsets[index];
    final Offset at = glyph.home + offset;
    if (scale == 1) {
      glyph.painter.paint(canvas, at);
      return;
    }
    final Offset center =
        at + Offset(glyph.painter.width / 2, glyph.painter.height / 2);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    canvas.translate(-center.dx, -center.dy);
    // 轻微投影，让"拿起来"的感觉更明确。
    glyph.painter.paint(canvas, at + const Offset(0, 2));
    glyph.painter.paint(canvas, at);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CloudPainter old) =>
      !identical(old.layout, layout) ||
      old.active != active ||
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
