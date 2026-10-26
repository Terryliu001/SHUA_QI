import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shuaqi/domain/records/records_stats.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 科目/题型词云：一个可以"搅"的字的沙盘。
///
/// ## 为什么重做（2026-10-26 用户第 3 轮）
/// 之前的版本只是"拖某个字 → 它回原位"，本质是拖拽，不是搅动；而且被动散开的
/// 字可能被推到框外。用户要的是：
/// - 整个科目分布框是一个沙盘；手指划过时，附近的字被带起来（有惯性）；
/// - 松手后字慢慢归位，**每次归位的位置可以不一样**，但都在中间汇聚；
/// - 同一个词（同一个文件夹）的字必须重新拼在一起，不能散掉。
///
/// ## 做法
/// 每个字是一个带速度的粒子；拖动只施加力，位置由物理步进决定；归位时
/// 随机重新排一遍词的位置，再把每个字的字内偏移加到词的目标上。
/// 所有位置都 clamp 在框内，撞边反弹，绝不出去。
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
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;

  _CloudLayout? _layout;
  Size _size = Size.zero;
  final List<_Particle> _particles = <_Particle>[];
  final math.Random _random = math.Random();

  bool _stirring = false;
  bool _settling = false;

  /// 物理步进用；给搅动力一个参考速度。
  double _lastDt = 1 / 60;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void didUpdateWidget(covariant RecordsWordCloud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.words != widget.words) {
      _resetParticles();
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  void _resetParticles() {
    _ticker?.stop();
    _stirring = false;
    _settling = false;
    _layout = null;
    _particles.clear();
    _lastElapsed = Duration.zero;
  }

  void _ensureParticles(_CloudLayout layout, Size size) {
    if (identical(_layout, layout) && _size == size) {
      return;
    }
    _layout = layout;
    _size = size;
    _particles
      ..clear()
      ..addAll(<_Particle>[
        for (int i = 0; i < layout.glyphs.length; i += 1)
          _Particle(glyph: layout.glyphs[i], pos: layout.glyphs[i].home),
      ]);
    _randomizeTargets();
  }

  /// 每次归位重新排一遍词：顺序随机、位置都在中心附近，同一词的字共用目标。
  void _randomizeTargets() {
    final _CloudLayout? layout = _layout;
    if (layout == null || _particles.isEmpty) {
      return;
    }
    final List<int> order = <int>[
      for (int i = 0; i < layout.words.length; i += 1) i,
    ]..shuffle(_random);
    final List<Rect> taken = <Rect>[];
    for (final int wordIndex in order) {
      final _PlacedWord word = layout.words[wordIndex];
      final Offset? spot = _findSpot(
        size: _size,
        center: Offset(_size.width / 2, _size.height / 2),
        wordSize: word.painter.size,
        taken: taken,
      );
      if (spot == null) {
        continue;
      }
      // 小抖动：每次归位都略有不同，但仍在中心附近、不破坏词内相对位置。
      final Offset targetSpot = Offset(
        (spot.dx + (_random.nextDouble() - 0.5) * 10).clamp(
          0,
          math.max(0, _size.width - word.painter.width),
        ),
        (spot.dy + (_random.nextDouble() - 0.5) * 8).clamp(
          0,
          math.max(0, _size.height - word.painter.height),
        ),
      );
      taken.add(
        Rect.fromLTWH(
          targetSpot.dx,
          targetSpot.dy,
          word.painter.width,
          word.painter.height,
        ).inflate(2.5),
      );
      for (final int glyphIndex in word.glyphIndices) {
        final _Glyph glyph = layout.glyphs[glyphIndex];
        final Offset local = glyph.home - word.offset;
        _particles[glyphIndex].target = _clampPosition(
          targetSpot + local,
          glyph,
          _size,
        );
      }
    }
  }

  void _beginStir(Offset point) {
    _stirring = true;
    _settling = false;
    _lastElapsed = Duration.zero;
    _lastDt = 1 / 60;
    // 第一下也给一个冲量：手指刚按下时就能感到"沙盘被碰了一下"。
    for (final _Particle particle in _particles) {
      final Size size = particle.glyph.painter.size;
      final Offset away = particle.pos + size.center(Offset.zero) - point;
      final double distance = away.distance;
      if (distance > 0.01 && distance < 110) {
        final Offset radial = away / distance;
        final Offset tangent = Offset(-radial.dy, radial.dx);
        particle.vel += tangent * (1 - distance / 110) * 160;
      }
    }
    if (_ticker?.isActive != true) {
      _ticker?.start();
    }
    setState(() {});
  }

  void _stir(Offset point, Offset delta) {
    final double speed = delta.distance / math.max(_lastDt, 0.008);
    const double radius = 88;
    for (final _Particle particle in _particles) {
      final Size glyphSize = particle.glyph.painter.size;
      final Offset center = particle.pos + glyphSize.center(Offset.zero);
      final Offset away = center - point;
      final double distance = away.distance;
      if (distance <= 0.01 || distance >= radius) {
        continue;
      }
      final Offset radial = away / distance;
      final Offset tangent = Offset(-radial.dy, radial.dx);
      final double falloff = 1 - distance / radius;
      // 切向为主 + 少量向外推：像手指划过沙盘，字被带起来而不是粘在手指上。
      final double force = falloff * (240 + speed * 1.6);
      particle.vel += (tangent + radial * 0.35) * force * _lastDt;
      particle.vel = _clampVelocity(particle.vel);
    }
  }

  void _beginSettle() {
    if (_particles.isEmpty) {
      return;
    }
    _stirring = false;
    _settling = true;
    _randomizeTargets();
    _lastElapsed = Duration.zero;
    if (_ticker?.isActive != true) {
      _ticker?.start();
    }
    setState(() {});
  }

  void _onTick(Duration elapsed) {
    final Duration previous = _lastElapsed;
    _lastElapsed = elapsed;
    final double dt = previous == Duration.zero
        ? 1 / 60
        : (elapsed - previous).inMicroseconds / 1000000;
    _lastDt = dt.clamp(0.008, 0.033);

    if (!_stirring && _settling) {
      for (final _Particle particle in _particles) {
        final Offset delta = particle.target - particle.pos;
        // 弹簧回位 + 阻尼：慢慢靠拢，不是瞬间吸回去。
        particle.vel += delta * 22 * _lastDt;
        particle.vel *= math.exp(-6.5 * _lastDt);
      }
    } else {
      for (final _Particle particle in _particles) {
        particle.vel *= math.exp(-1.8 * _lastDt);
      }
    }

    bool allHome = true;
    for (final _Particle particle in _particles) {
      final Size glyphSize = particle.glyph.painter.size;
      Offset next = particle.pos + particle.vel * _lastDt;
      final double maxX = math.max(0, _size.width - glyphSize.width);
      final double maxY = math.max(0, _size.height - glyphSize.height);
      if (next.dx < 0 || next.dx > maxX) {
        next = Offset(next.dx.clamp(0, maxX), next.dy);
        particle.vel = Offset(-particle.vel.dx * 0.28, particle.vel.dy);
      }
      if (next.dy < 0 || next.dy > maxY) {
        next = Offset(next.dx, next.dy.clamp(0, maxY));
        particle.vel = Offset(particle.vel.dx, -particle.vel.dy * 0.28);
      }
      particle.pos = next;

      if (_settling &&
          ((particle.pos - particle.target).distance > 0.8 ||
              particle.vel.distance > 12)) {
        allHome = false;
      }
    }

    if (_settling && !_stirring && allHome) {
      for (final _Particle particle in _particles) {
        particle.pos = particle.target;
        particle.vel = Offset.zero;
      }
      _settling = false;
      _ticker?.stop();
      setState(() {});
      return;
    }
    setState(() {});
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
          _ensureParticles(layout, size);
          final int hidden = widget.words.length - layout.words.length;
          final List<Offset> positions = <Offset>[
            for (final _Particle particle in _particles) particle.pos,
          ];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (DragStartDetails details) =>
                _beginStir(details.localPosition),
            onPanUpdate: (DragUpdateDetails details) =>
                _stir(details.localPosition, details.delta),
            onPanEnd: (_) => _beginSettle(),
            onPanCancel: _beginSettle,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                IgnorePointer(
                  child: CustomPaint(
                    painter: _CloudPainter(
                      layout: layout,
                      positions: positions,
                    ),
                  ),
                ),
                if (hidden > 0)
                  Positioned(
                    right: 4,
                    bottom: 2,
                    child: IgnorePointer(
                      child: Text(
                        '+$hidden',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.outline,
                          fontSize: 9,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Particle {
  _Particle({required this.glyph, required this.pos}) : target = pos;

  final _Glyph glyph;
  Offset pos;
  Offset vel = Offset.zero;
  Offset target;
}

class _Glyph {
  const _Glyph({required this.painter, required this.home});

  final TextPainter painter;

  /// 字在词里的原始位置；归位目标按"词的位置 + 字内偏移"算。
  final Offset home;

  void dispose() => painter.dispose();
}

class _PlacedWord {
  const _PlacedWord({
    required this.painter,
    required this.offset,
    required this.glyphIndices,
  });

  final TextPainter painter;
  final Offset offset;

  /// 这个词拆出来的字在 [_CloudLayout.glyphs] 里的下标；归位时整组移动。
  final List<int> glyphIndices;
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

/// 按可用面积决定参与布局的词数：手机窄框少放几个，平板多放几个。
/// 放不下的词由调用方在右下角标 `+N`，不假装全都画出来了。
int _maxWordsFor(Size size) {
  final int density = (size.width * size.height / 9000).floor();
  return math.min(_kMaxWords, math.max(8, density));
}

/// 布局缓存（尺寸/数据变了才重排）。上限 3 份，避免旋转/切页时堆积。
final Map<String, _CloudLayout> _layoutCache = <String, _CloudLayout>{};

_CloudLayout _layoutFor({
  required Size size,
  required List<CloudWord> words,
  required Color low,
  required Color high,
  required TextScaler textScaler,
}) {
  final int maxWords = _maxWordsFor(size);
  final List<CloudWord> top = words.take(maxWords).toList(growable: false);
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
  // 词多时先整体缩字号，再重排；能全放下就停。
  // 只在极端长词/极小高度下才允许丢最末几个词（词云本来就是摘要）。
  _CloudLayout? best;
  for (int attempt = 0; attempt < 5; attempt += 1) {
    final double fontScale = math.pow(0.84, attempt).toDouble();
    final _CloudLayout layout = _layoutWords(
      top: top,
      size: size,
      low: low,
      high: high,
      textScaler: textScaler,
      maxWeight: maxWeight,
      fontScale: fontScale,
    );
    if (layout.words.length == top.length) {
      best?.dispose();
      _cacheLayout(signature, layout);
      return layout;
    }
    if (best == null || layout.words.length > best.words.length) {
      best?.dispose();
      best = layout;
    } else {
      layout.dispose();
    }
    if (fontScale < 0.56) {
      break;
    }
  }
  final _CloudLayout layout =
      best ?? const _CloudLayout(<_PlacedWord>[], <_Glyph>[]);
  _cacheLayout(signature, layout);
  return layout;
}

void _cacheLayout(String signature, _CloudLayout layout) {
  if (_layoutCache.length >= 3) {
    final String firstKey = _layoutCache.keys.first;
    _layoutCache.remove(firstKey)?.dispose();
  }
  _layoutCache[signature] = layout;
}

_CloudLayout _layoutWords({
  required List<CloudWord> top,
  required Size size,
  required Color low,
  required Color high,
  required TextScaler textScaler,
  required double maxWeight,
  required double fontScale,
}) {
  final List<_PlacedWord> placed = <_PlacedWord>[];
  final List<_Glyph> glyphs = <_Glyph>[];
  final List<Rect> taken = <Rect>[];
  final Offset center = Offset(size.width / 2, size.height / 2);

  for (final CloudWord word in top) {
    double font =
        cloudFontSize(
          word.weight,
          maxWeight: maxWeight,
          min: 11,
          max: math.min(30, size.height / 4.2),
        ) *
        fontScale;
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
        final int start = glyphs.length;
        _splitGlyphs(
          word: word.label,
          style: style.copyWith(letterSpacing: 0),
          wordRect: rect,
          textScaler: textScaler,
          out: glyphs,
        );
        placed.add(
          _PlacedWord(
            painter: painter,
            offset: spot,
            glyphIndices: <int>[
              for (int i = start; i < glyphs.length; i += 1) i,
            ],
          ),
        );
        taken.add(rect.inflate(2.5));
        break;
      }
      painter.dispose();
      font *= 0.85;
      if (font < 7) {
        break;
      }
    }
  }
  return _CloudLayout(placed, glyphs);
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

Offset _clampPosition(Offset pos, _Glyph glyph, Size size) {
  final double maxX = math.max(0, size.width - glyph.painter.width);
  final double maxY = math.max(0, size.height - glyph.painter.height);
  return Offset(pos.dx.clamp(0, maxX), pos.dy.clamp(0, maxY));
}

Offset _clampVelocity(Offset velocity) {
  const double max = 1100;
  if (velocity.distance <= max) {
    return velocity;
  }
  return velocity / velocity.distance * max;
}

class _CloudPainter extends CustomPainter {
  const _CloudPainter({required this.layout, required this.positions});

  final _CloudLayout layout;
  final List<Offset> positions;

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < layout.glyphs.length; i += 1) {
      final _Glyph glyph = layout.glyphs[i];
      final Offset at = positions[i];
      // 轻投影：字被带起来时有一点"离开沙盘"的层次，但不抢正文。
      glyph.painter.paint(canvas, at + const Offset(0, 1.2));
      glyph.painter.paint(canvas, at);
    }
  }

  @override
  bool shouldRepaint(_CloudPainter old) =>
      !identical(old.layout, layout) ||
      !_samePositions(old.positions, positions);

  static bool _samePositions(List<Offset> a, List<Offset> b) {
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
