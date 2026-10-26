import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/region_set.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/ui/panel/question_thumb.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 答题卡第一步：**确认切题**。
///
/// 设计口径（2026-10-24 用户需求）：
/// - 用户点顶栏「答题卡」后，先看到按题号排列的**整题概览**，确认切题没切错；
/// - 确认后再进入逐题作答；切题有误时回「题目区域」调，不在这里重复造一套切题 UI；
/// - 概览用 [QuestionThumb] 整题缩放，不是 `RegionPreview` 的纵向裁切——
///   确认切题必须看到完整区域。
///
/// 逐题作答画布是下一步：它需要独立的作答笔迹存储，不能和 PDF 页笔迹混在一起。
/// 答题卡确认结果：开始逐题作答，或回原卷调整切题。
enum AnswerSheetPrepAction { start, adjust }

class AnswerSheetPrepResult {
  const AnswerSheetPrepResult(this.action, {this.questionId});

  const AnswerSheetPrepResult.start()
    : action = AnswerSheetPrepAction.start,
      questionId = null;

  const AnswerSheetPrepResult.adjust({this.questionId})
    : action = AnswerSheetPrepAction.adjust;

  final AnswerSheetPrepAction action;
  final String? questionId;
}

Future<AnswerSheetPrepResult?> showAnswerSheetPrep(
  BuildContext context, {
  required String workbookId,
  required RegionSet set,
  required List<WbPage> pages,
  required PageImageCache cache,
}) {
  return showModalBottomSheet<AnswerSheetPrepResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
    ),
    builder: (BuildContext context) => FractionallySizedBox(
      heightFactor: 0.92,
      child: AnswerSheetPrep(
        workbookId: workbookId,
        set: set,
        pages: pages,
        cache: cache,
      ),
    ),
  );
}

class AnswerSheetPrep extends StatelessWidget {
  const AnswerSheetPrep({
    super.key,
    required this.workbookId,
    required this.set,
    required this.pages,
    required this.cache,
  });

  final String workbookId;
  final RegionSet set;
  final List<WbPage> pages;
  final PageImageCache cache;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<QuestionBundle> all = <QuestionBundle>[
      for (final QuestionBundle bundle in set.questions)
        if (bundle.slices.isNotEmpty) bundle,
    ];
    // 答题卡是"逐道小题作答"：大题（level 1）只是章节容器，不单独成卡。
    // 如果整卷没有 level 2（极端数据），才回退到全部。
    final List<QuestionBundle> subQuestions = <QuestionBundle>[
      for (final QuestionBundle bundle in all)
        if (bundle.question.level > 1) bundle,
    ];
    final List<QuestionBundle> questions = subQuestions.isEmpty
        ? all
        : subQuestions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.lg,
            ShqSpace.md,
            ShqSpace.sm,
            ShqSpace.sm,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.assignment_outlined,
                size: 22,
                color: scheme.primary,
              ),
              const SizedBox(width: ShqSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('答题卡', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 2),
                    Text(
                      '先确认题目切题；开始后按题号逐题作答',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ShqSpace.lg),
          child: Container(
            padding: const EdgeInsets.all(ShqSpace.sm),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShqRadius.md),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: ShqSpace.sm),
                Expanded(
                  child: Text(
                    '共 ${questions.length} 道题 · 共 ${pages.length} 页。'
                    '切题不对时先回「题目区域」调整，再打开答题卡。',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: ShqSpace.sm),
        Expanded(
          child: questions.isEmpty
              ? Center(
                  child: Text(
                    '还没有切出题目',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final int columns = constraints.maxWidth >= 1000
                        ? 3
                        : constraints.maxWidth >= 620
                        ? 2
                        : 1;
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(
                        ShqSpace.lg,
                        0,
                        ShqSpace.lg,
                        ShqSpace.md,
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: ShqSpace.md,
                        mainAxisSpacing: ShqSpace.md,
                        mainAxisExtent: 236,
                      ),
                      itemCount: questions.length,
                      itemBuilder: (BuildContext context, int index) {
                        final QuestionBundle bundle = questions[index];
                        return _QuestionConfirmCard(
                          bundle: bundle,
                          cache: cache,
                          pages: pages,
                        );
                      },
                    );
                  },
                ),
        ),
        Divider(height: 1, color: scheme.outlineVariant),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.lg,
            ShqSpace.sm,
            ShqSpace.lg,
            ShqSpace.md,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '点卡片可直接回原卷拖动该题框；确认题号无误后开始逐题作答。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: ShqSpace.md),
              TextButton.icon(
                onPressed: () => Navigator.of(
                  context,
                ).pop(const AnswerSheetPrepResult.adjust()),
                icon: const Icon(Icons.crop_free, size: 16),
                label: const Text('原卷调整'),
              ),
              const SizedBox(width: ShqSpace.xs),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(
                  const AnswerSheetPrepResult.start(),
                ),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('开始逐题作答'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _QuestionConfirmCard extends StatelessWidget {
  const _QuestionConfirmCard({
    required this.bundle,
    required this.cache,
    required this.pages,
  });

  final QuestionBundle bundle;
  final PageImageCache cache;
  final List<WbPage> pages;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final QuestionSlice slice = bundle.slices.first;
    if (slice.pageIndex < 0 || slice.pageIndex >= pages.length) {
      return const SizedBox.shrink();
    }
    final String label = bundle.question.label ?? '${bundle.question.ordinal}';
    final String? stem = bundle.question.stemText;
    return Tooltip(
      message: '点一下回原卷调整这道题的框',
      child: InkWell(
        onTap: () => Navigator.of(context).pop(
          AnswerSheetPrepResult.adjust(questionId: bundle.question.id),
        ),
        borderRadius: BorderRadius.circular(ShqRadius.md),
        child: Container(
          padding: const EdgeInsets.all(ShqSpace.sm),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(ShqRadius.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    constraints: const BoxConstraints(minWidth: 28),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(ShqRadius.sm),
                    ),
                    child: Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: ShqSpace.sm),
                  Text(
                    '第 ${slice.pageIndex + 1} 页'
                    '${bundle.slices.length > 1 ? ' · ${bundle.slices.length} 段' : ''}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.crop_free,
                    size: 15,
                    color: scheme.outline,
                  ),
                ],
              ),
              const SizedBox(height: ShqSpace.xs),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return QuestionThumb(
                      cache: cache,
                      page: pages[slice.pageIndex],
                      rect: slice.rect,
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                      paperColor: scheme.surface,
                    );
                  },
                ),
              ),
              if (stem != null && stem.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: ShqSpace.xxs),
                Text(
                  stem.trim().replaceAll(RegExp(r'\s+'), ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
