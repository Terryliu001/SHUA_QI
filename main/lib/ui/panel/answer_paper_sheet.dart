import 'package:flutter/material.dart';
import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 纸张设置的结果：新配置 + 是否应用到本卷所有题目。
class AnswerPaperChange {
  const AnswerPaperChange({required this.paper, required this.applyAll});

  final AnswerPaper paper;
  final bool applyAll;
}

/// 答题卡「纸张」浮层（用户第 1 条）。
///
/// 四组选项：尺寸 / 方向 / 张数 / 纸样式。默认值就是现在用的那套，
/// 所以"不改就是原来的样子"；改完可以选择只应用当前题，或整卷一起换。
///
/// 2026-10-25：收藏「重刷」复用同一个浮层——它每道收藏只有一张纸的归属，
/// 所以 [showApplyAll] 关掉；[showPages] 打开（重刷页没有画布上的「＋」，
/// 张数必须能在这里设）。
Future<AnswerPaperChange?> showAnswerPaperSheet(
  BuildContext context, {
  required AnswerPaper current,
  required String questionLabel,
  bool showApplyAll = true,
  bool showPages = false,
}) {
  return showModalBottomSheet<AnswerPaperChange>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
    ),
    builder: (BuildContext context) => _AnswerPaperSheet(
      current: current,
      questionLabel: questionLabel,
      showApplyAll: showApplyAll,
      showPages: showPages,
    ),
  );
}

class _AnswerPaperSheet extends StatefulWidget {
  const _AnswerPaperSheet({
    required this.current,
    required this.questionLabel,
    required this.showApplyAll,
    required this.showPages,
  });

  final AnswerPaper current;
  final String questionLabel;
  final bool showApplyAll;
  final bool showPages;

  @override
  State<_AnswerPaperSheet> createState() => _AnswerPaperSheetState();
}

class _AnswerPaperSheetState extends State<_AnswerPaperSheet> {
  late AnswerPaper _paper = widget.current;
  bool _applyAll = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        0,
        ShqSpace.lg,
        ShqSpace.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.description_outlined, size: 20, color: scheme.primary),
              const SizedBox(width: ShqSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('答题纸', style: theme.textTheme.titleMedium),
                    Text(
                      '第 ${widget.questionLabel} 题 · ${_paper.summary}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: ShqSpace.md),
          _Group(
            title: '尺寸',
            child: SegmentedButton<AnswerPaperSize>(
              segments: <ButtonSegment<AnswerPaperSize>>[
                for (final AnswerPaperSize size in AnswerPaperSize.values)
                  ButtonSegment<AnswerPaperSize>(
                    value: size,
                    label: Text(size.label),
                  ),
              ],
              selected: <AnswerPaperSize>{_paper.size},
              showSelectedIcon: false,
              onSelectionChanged: (Set<AnswerPaperSize> value) =>
                  setState(() => _paper = _paper.copyWith(size: value.first)),
            ),
          ),
          _Group(
            title: '方向',
            child: SegmentedButton<AnswerPaperOrientation>(
              segments: <ButtonSegment<AnswerPaperOrientation>>[
                for (final AnswerPaperOrientation o
                    in AnswerPaperOrientation.values)
                  ButtonSegment<AnswerPaperOrientation>(
                    value: o,
                    label: Text(o.label),
                  ),
              ],
              selected: <AnswerPaperOrientation>{_paper.orientation},
              showSelectedIcon: false,
              onSelectionChanged: (Set<AnswerPaperOrientation> value) =>
                  setState(
                    () => _paper = _paper.copyWith(orientation: value.first),
                  ),
            ),
          ),
          // 张数默认放在书写区（左右翻页键 +「＋」）；重刷页没有那套控件，
          // 由 [showPages] 在这里给一个加减器。
          if (widget.showPages)
            _Group(
              title: '张数',
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: '少一张',
                    onPressed: _paper.pages <= 1
                        ? null
                        : () => setState(
                            () => _paper = _paper.copyWith(
                              pages: _paper.pages - 1,
                            ),
                          ),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text(
                    '${_paper.pages} 张',
                    style: theme.textTheme.titleSmall,
                  ),
                  IconButton(
                    tooltip: '多一张',
                    onPressed: _paper.pages >= AnswerPaper.maxPages
                        ? null
                        : () => setState(
                            () => _paper = _paper.copyWith(
                              pages: _paper.pages + 1,
                            ),
                          ),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                  const SizedBox(width: ShqSpace.md),
                  Flexible(
                    child: Text(
                      '每张纸各一份笔迹，按顺序都算这一题的作答',
                      maxLines: 2,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          _Group(
            title: '纸样式',
            child: Wrap(
              spacing: ShqSpace.sm,
              runSpacing: ShqSpace.sm,
              children: <Widget>[
                for (final AnswerPaperRule rule in AnswerPaperRule.values)
                  ChoiceChip(
                    label: Text(rule.label),
                    selected: _paper.rule == rule,
                    onSelected: (_) =>
                        setState(() => _paper = _paper.copyWith(rule: rule)),
                  ),
              ],
            ),
          ),
          if (widget.showApplyAll)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _applyAll,
              onChanged: (bool value) => setState(() => _applyAll = value),
              title: const Text('应用到本卷所有题目'),
              subtitle: const Text('关掉 = 只改这一题，其它题沿用全局默认'),
            ),
          const SizedBox(height: ShqSpace.xs),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '横向 A4 = 842×595pt；换成别的尺寸时，已有笔迹会按比例搬过去。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: ShqSpace.md),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(
                  AnswerPaperChange(paper: _paper, applyAll: _applyAll),
                ),
                child: const Text('完成'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: ShqSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}
