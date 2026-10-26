import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/answer_sheet.dart';
import 'package:shuaqi/domain/region/answer.dart';
import 'package:shuaqi/ui/panel/answer_ink_preview.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/math/math_text.dart';

/// 题目区域里展开的「答题情况」卡（2026-10-24 第二轮重做）。
///
/// 用户口径（第 2、4 条）：
/// - **只留一栏**：有答题卡笔迹就显示答题卡画面；没有就当作"直接在卷面上写的"，
///   显示白底 + 该作答框里的笔画。**不再有「题面」那一栏**（和上面的题面预览重复）。
/// - **双击**切换成"题面 + 书写合并"的图：题面与书写不完全重合时，
///   以题面能覆盖到的总区域来裁（合成交给上层渲染，这里只负责显示与缓存）。
/// - 没有手写作答、也没有可识别文字时，预览区中央给「点这里去写」（直达这道题）。
/// - 长按照片出侧边浮窗；点击开大图。「调整答题框 / 下载 / 识别」三个按钮都不在这里。
class AnswerStatusCard extends StatefulWidget {
  const AnswerStatusCard({
    super.key,
    required this.entry,
    required this.strokeCount,
    required this.answerNote,
    required this.onJump,
    this.answerInkCount = -1,
    this.answerInk,
    this.pageInk,
    this.pageWidth = 0,
    this.pageHeight = 0,
    this.recognizing = false,
    this.onRegenerate,
    this.onPreview,
    this.onLongPress,
    this.onOpenSheet,
    this.onRenderMerged,
    this.onAskAi,
  });

  final AnswerSheetEntry entry;

  /// 当前作答框内的手写笔数（PDF 页内）。`-1` = 不在当前页，未统计。
  final int strokeCount;

  final AnswerNote? answerNote;

  /// 跳到作答页（题目不在当前页时用）。
  final VoidCallback onJump;

  /// 答题卡画布上的笔数；`-1` = 还没统计。
  final int answerInkCount;

  /// 答题卡当前手写内容（实时画，不是截图）。
  final InkDoc? answerInk;

  /// PDF 页内、落在这个作答框里的笔画（没有答题卡笔迹时显示它）。
  final InkDoc? pageInk;

  /// 页内笔迹所在的页面尺寸（pt），用于把框内坐标映射到预览。
  final double pageWidth;
  final double pageHeight;

  /// 后台正在识别（自动触发，没有按钮）。
  final bool recognizing;

  final VoidCallback? onRegenerate;
  final VoidCallback? onPreview;
  final VoidCallback? onLongPress;

  /// 还没有任何作答：去答题卡写这道题。
  final VoidCallback? onOpenSheet;

  /// 生成"题面 + 书写合并图"（双击时按需调用，结果缓存到本卡）。
  final Future<Uint8List?> Function()? onRenderMerged;

  final VoidCallback? onAskAi;

  @override
  State<AnswerStatusCard> createState() => _AnswerStatusCardState();
}

class _AnswerStatusCardState extends State<AnswerStatusCard> {
  /// true = 正在显示"题面 + 书写合并图"，false = 只显示书写。
  bool _merged = false;
  Uint8List? _mergedBytes;
  bool _rendering = false;

  bool get _hasSheetInk =>
      widget.answerInk != null && widget.answerInk!.strokes.isNotEmpty;

  bool get _hasPageInk =>
      widget.pageInk != null && widget.pageInk!.strokes.isNotEmpty;

  bool get _hasInk => _hasSheetInk || _hasPageInk;

  @override
  void didUpdateWidget(covariant AnswerStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换题/换笔迹：合并图作废，回到"只显示书写"。
    if (oldWidget.entry.questionId != widget.entry.questionId ||
        oldWidget.answerInk?.revision != widget.answerInk?.revision) {
      _merged = false;
      _mergedBytes = null;
    }
  }

  Future<void> _toggleMerged() async {
    if (!_hasInk || widget.onRenderMerged == null) {
      return;
    }
    if (_merged) {
      setState(() => _merged = false);
      return;
    }
    setState(() {
      _merged = true;
      _rendering = _mergedBytes == null;
    });
    if (_mergedBytes != null) {
      return;
    }
    final Uint8List? bytes = await widget.onRenderMerged!();
    if (!mounted) {
      return;
    }
    setState(() {
      _mergedBytes = bytes;
      _rendering = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String pageLabel = '第 ${widget.entry.pageIndex + 1} 页';
    final String strokeLabel = widget.strokeCount < 0
        ? '切到该页后统计'
        : widget.strokeCount == 0
        ? '页内无笔迹'
        : '${widget.strokeCount} 笔';
    // "什么都没有"：既没有笔迹、也没有识别文字 → 给「点这里去写」。
    final bool empty = !_hasInk && !widget.entry.hasText;
    return GestureDetector(
      // 双击整卡 = 在"纯书写"和"题面+书写合并"之间切（用户第 2 条）。
      onDoubleTap: _hasInk ? () => _toggleMerged() : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(
          ShqSpace.sm,
          ShqSpace.xs,
          ShqSpace.sm,
          ShqSpace.sm,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShqRadius.md),
          border: Border.all(color: ShqRegion.answer.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.edit_note, size: 16, color: ShqRegion.answer),
                const SizedBox(width: 5),
                Text('答题情况', style: theme.textTheme.labelMedium),
                if (widget.entry.manuallyAdjusted) ...<Widget>[
                  const SizedBox(width: 5),
                  const _Tag(text: '手调', color: ShqRegion.answer),
                ],
                if (widget.entry.ocrStale && !widget.recognizing) ...<Widget>[
                  const SizedBox(width: 5),
                  _Tag(text: '待重识别', color: scheme.outline),
                ],
                const Spacer(),
                if (widget.recognizing)
                  const Padding(
                    padding: EdgeInsets.only(right: ShqSpace.sm),
                    child: SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    ),
                  ),
                IconButton(
                  tooltip: widget.answerNote == null ? '问 AI' : '重新生成',
                  onPressed: widget.onRegenerate == null
                      ? null
                      : (widget.answerNote == null
                            ? widget.onAskAi
                            : widget.onRegenerate),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 30,
                    height: 30,
                  ),
                  iconSize: 17,
                  icon: Icon(
                    widget.answerNote == null
                        ? Icons.auto_awesome
                        : Icons.refresh,
                    color: widget.answerNote == null
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _hasInk
                  ? widget.onPreview
                  : (widget.onOpenSheet ?? widget.onJump),
              onLongPress: _hasInk ? widget.onLongPress : null,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(ShqRadius.sm),
                child: SizedBox(
                  height: 96,
                  width: double.infinity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: ShqPaper.base,
                      border: Border.all(color: scheme.outlineVariant),
                      borderRadius: BorderRadius.circular(ShqRadius.sm),
                    ),
                    child: _buildPreview(theme, scheme, empty: empty),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '$pageLabel · $strokeLabel'
                    '${widget.answerInkCount >= 0 ? ' · 答题卡 ${widget.answerInkCount} 笔' : ''}'
                    '${_hasInk ? (_merged ? ' · 题面+书写' : ' · 双击看题面') : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                      fontSize: ShqType.caption,
                    ),
                  ),
                ),
                if (widget.strokeCount < 0 || empty)
                  TextButton.icon(
                    onPressed: widget.onJump,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(0, 24),
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.my_location, size: 12),
                    label: const Text('跳到作答页'),
                  ),
              ],
            ),
            if (widget.recognizing) ...<Widget>[
              Text(
                '正在识别手写…',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.primary,
                  fontSize: ShqType.caption,
                ),
              ),
            ] else if (widget.entry.hasText) ...<Widget>[
              Text(
                '识别：${widget.entry.ocrText}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurface,
                  height: 1.35,
                ),
              ),
            ],
            if (widget.answerNote != null) ...<Widget>[
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(ShqRadius.sm),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          '参考答案',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _answerSourceLabel(widget.answerNote!.source),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.outline,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    MathText(
                      widget.answerNote!.text,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                    ),
                  ],
                ),
              ),
            ] else ...<Widget>[
              const SizedBox(height: 2),
              Text(
                'PDF 未收录答案',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(
    ThemeData theme,
    ColorScheme scheme, {
    required bool empty,
  }) {
    if (empty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.draw_outlined, size: 20, color: scheme.primary),
            const SizedBox(height: 2),
            Text(
              '点这里去写',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.primary,
                fontSize: ShqType.caption,
              ),
            ),
          ],
        ),
      );
    }
    if (_merged) {
      if (_rendering) {
        return const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      final Uint8List? bytes = _mergedBytes;
      if (bytes == null) {
        return Center(
          child: Text(
            '合并图生成失败',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
          ),
        );
      }
      return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
    }
    if (_hasSheetInk) {
      return AnswerInkPreview(doc: widget.answerInk!);
    }
    if (_hasPageInk) {
      // 没有答题卡笔迹：当作"直接在卷面上写的"，只看这个作答框里的笔画。
      return AnswerInkPreview(
        doc: widget.pageInk!,
        region: widget.entry.rect,
        canvasWidth: widget.pageWidth > 0 ? widget.pageWidth : 1000,
        canvasHeight: widget.pageHeight > 0 ? widget.pageHeight : 1000,
      );
    }
    // 有识别文字但已经没有笔迹（例如文字是手工/OCR 留下的）——不假装有图。
    return Center(
      child: Text(
        '暂无笔迹预览',
        style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ShqRadius.sm),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontSize: ShqType.caption - 0.5,
        ),
      ),
    );
  }
}

String _answerSourceLabel(String source) {
  switch (source) {
    case 'pdf_text':
      return 'PDF';
    case 'inline':
      return '卷内';
    case 'ocr':
      return 'OCR';
    case 'manual':
      return '手工';
    case 'ai':
      return 'AI';
    default:
      return source.isEmpty ? '未知' : source;
  }
}
