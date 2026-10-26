import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart' as flutter_math;
import 'package:shuaqi/domain/markup/math_segmenter.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/math/math_view.dart';

/// 公式渲染的唯一实现（T6.7）。
///
/// 三条硬约束：
/// 1. **未闭合的定界符绝不进这里**——由 `segmentMath` 先当普通文本；
/// 2. 渲染失败返回 [fallback]（源码），不抛异常、不空白；
/// 3. 不做 Widget 实例复用缓存。
///
/// 第 3 条是 2026-10-24 真机踩出来的：同一个 `Math` Widget 实例被两条消息
/// 同时缓存复用时，先出现的那条气泡会在下一次 rebuild 后**停止绘制公式**
/// （文字还在、公式位置空白）。聊天气泡数量很少，每次重新解析的成本远低于
/// 这种"公式消失"的可见缺陷；真要缓存应缓存 AST，而不是 Widget。
class ShqMathView implements MathView {
  ShqMathView();

  @override
  Widget build(
    BuildContext context,
    String tex, {
    bool display = false,
    Widget? fallback,
  }) {
    final TextStyle base = DefaultTextStyle.of(context).style
        .merge(Theme.of(context).textTheme.bodyMedium);
    final double fontSize = (base.fontSize ?? ShqType.body).clamp(10, 40);
    final Color color = base.color ?? Theme.of(context).colorScheme.onSurface;
    final Widget fallbackWidget =
        fallback ??
        Text(
          tex,
          style: base.copyWith(
            fontFamily: 'monospace',
            fontSize: fontSize,
            color: color,
          ),
        );
    return flutter_math.Math.tex(
      tex,
      mathStyle: display
          ? flutter_math.MathStyle.display
          : flutter_math.MathStyle.text,
      textStyle: base.copyWith(fontSize: fontSize + 0.5, color: color),
      onErrorFallback: (Object error) => fallbackWidget,
    );
  }
}

/// 文本 + 公式混排。
///
/// - 行内公式用 `WidgetSpan` 嵌入，与文字基线居中；
/// - 行间公式独占一行、居中、超宽自动缩小（窄面板不横向溢出）；
/// - 一段文本里没有公式时退回普通 `Text`，不多包一层。
class MathText extends StatelessWidget {
  const MathText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
  });

  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  static final ShqMathView _math = ShqMathView();

  @override
  Widget build(BuildContext context) {
    final TextStyle effective =
        style ??
        DefaultTextStyle.of(context).style
            .merge(Theme.of(context).textTheme.bodySmall);
    final List<MathSegment> segments = segmentMath(text);
    final bool hasFormula = segments.any(
      (MathSegment segment) => segment is FormulaSegment,
    );
    if (!hasFormula) {
      return Text(text, style: effective, textAlign: textAlign, softWrap: true);
    }
    final List<Widget> blocks = <Widget>[];
    List<InlineSpan> spans = <InlineSpan>[];

    void flushParagraph() {
      if (spans.isEmpty) {
        return;
      }
      blocks.add(
        Text.rich(
          TextSpan(children: spans),
          style: effective,
          textAlign: textAlign,
          softWrap: true,
        ),
      );
      spans = <InlineSpan>[];
    }

    void addText(String value) {
      if (value.isEmpty) {
        return;
      }
      final List<String> lines = value.split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (i > 0) {
          flushParagraph();
        }
        if (lines[i].isNotEmpty) {
          spans.add(TextSpan(text: lines[i]));
        }
      }
    }

    for (final MathSegment segment in segments) {
      switch (segment) {
        case TextSegment():
          addText(segment.text);
        case FormulaSegment():
          if (segment.display) {
            flushParagraph();
            blocks.add(
              Padding(
                padding: const EdgeInsets.symmetric(vertical: ShqSpace.xs),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: _math.build(context, segment.tex, display: true),
                  ),
                ),
              ),
            );
          } else {
            spans.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: _math.build(context, segment.tex),
              ),
            );
          }
      }
    }
    flushParagraph();
    if (blocks.length == 1) {
      return blocks.first;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < blocks.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 2),
          blocks[i],
        ],
      ],
    );
  }
}
