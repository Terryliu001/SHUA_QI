import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shuaqi/domain/ai/ai_response.dart';
import 'package:shuaqi/domain/markup/code_blocks.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/math/math_text.dart';

/// AI 回复的富文本：普通文本 + LaTeX + fenced code block。
///
/// 顺序很重要：**先切代码块，再切公式**。代码里的 `$` 不能被当成 LaTeX。
/// 代码块自带复制按钮；文本块保留选择能力。
class ChatContent extends StatelessWidget {
  const ChatContent(this.text, {super.key, this.style, this.onCopied});

  final String text;
  final TextStyle? style;
  final void Function(String code)? onCopied;

  @override
  Widget build(BuildContext context) {
    final List<ContentBlock> blocks = splitCodeBlocks(text);
    if (blocks.isEmpty) {
      return const SizedBox.shrink();
    }
    final List<Widget> children = <Widget>[];
    for (final ContentBlock block in blocks) {
      switch (block) {
        case TextBlock():
          final String plain = stripLightMarkdown(block.text);
          if (plain.trim().isEmpty) {
            continue;
          }
          children.add(SelectionArea(child: MathText(plain, style: style)));
        case CodeBlock():
          children.add(
            _CodeBlock(
              code: block.code,
              language: block.language,
              onCopied: onCopied,
            ),
          );
      }
    }
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: ShqSpace.sm),
          children[i],
        ],
      ],
    );
  }
}

class _CodeBlock extends StatefulWidget {
  const _CodeBlock({required this.code, required this.language, this.onCopied});

  final String code;
  final String language;
  final void Function(String code)? onCopied;

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    widget.onCopied?.call(widget.code);
    if (!mounted) {
      return;
    }
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String language = widget.language.trim().isEmpty
        ? 'code'
        : widget.language.trim();
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(ShqRadius.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(ShqSpace.sm, 2, 2, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    language,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _copied ? '已复制' : '复制代码',
                  onPressed: () => unawaited(_copy()),
                  iconSize: 15,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  icon: Icon(
                    _copied ? Icons.check : Icons.copy_all_outlined,
                    color: _copied ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ShqSpace.sm,
              0,
              ShqSpace.sm,
              ShqSpace.sm,
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                widget.code,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.5,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
