import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/model/question_kind.dart';
import 'package:shuaqi/domain/model/shelf_folder.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/records/answer_log.dart';
import 'package:shuaqi/domain/records/record_time.dart';
import 'package:shuaqi/domain/records/records_stats.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/record_providers.dart';
import 'package:shuaqi/state/shell_providers.dart';
import 'package:shuaqi/ui/bookshelf/workbook_menu_sheet.dart';
import 'package:shuaqi/ui/panel/grade_dot.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/empty_state.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';

/// 「作答时间线」——记录页的下一层：按天回看做过哪些卷、哪些题。
///
/// ## 为什么和书架/收藏夹长得不一样
/// - 书架是"检索与管理"：封面大图卡、文件夹、标签——目标是**找到**；
/// - 收藏夹是"题目陈列"：题面缩略图卡——目标是**挑题**；
/// - 时间线是"行为回放"：一条日期轴 + **逐题判定色带**——目标是**看见自己怎么练的**。
///   色带（一格一题、按判定上色）是这里独有的一层信息：一眼看出那天是"一片绿"
///   还是"红黄混杂"，这是封面图和题面图都给不了的。
///
/// ## 两种呈现
/// - **按试卷**（默认）：一天一张卷卡，点卡回原卷该次的第一题；
/// - **按题目**：同一天里逐题列出，点哪题就回哪题（精确到 questionId）。
class RecordsTimelinePage extends ConsumerStatefulWidget {
  const RecordsTimelinePage({super.key});

  @override
  ConsumerState<RecordsTimelinePage> createState() =>
      _RecordsTimelinePageState();
}

enum _TimelineMode { byWorkbook, byQuestion }

class _RecordsTimelinePageState extends ConsumerState<RecordsTimelinePage> {
  _TimelineMode _mode = _TimelineMode.byWorkbook;

  /// 展开了哪些组（组键见 `records_stats._groupKeyOf`）。
  ///
  /// 2026-10-26 用户第 16 条："重刷的记录…不直接展开重刷答题卡，
  /// 按记录的列表可以展开查看"——所以组卷/重刷这两类卡**点开是展开**，
  /// 不是跳去重刷页。
  final Set<String> _expandedGroups = <String>{};

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<TimelineDay>> async = ref.watch(
      recordsTimelineProvider,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('作答时间线'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: ShqSpace.md),
            child: SegmentedButton<_TimelineMode>(
              segments: const <ButtonSegment<_TimelineMode>>[
                ButtonSegment<_TimelineMode>(
                  value: _TimelineMode.byWorkbook,
                  label: Text('按试卷'),
                ),
                ButtonSegment<_TimelineMode>(
                  value: _TimelineMode.byQuestion,
                  label: Text('按题目'),
                ),
              ],
              selected: <_TimelineMode>{_mode},
              showSelectedIcon: false,
              onSelectionChanged: (Set<_TimelineMode> selection) {
                setState(() => _mode = selection.first);
              },
            ),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stackTrace) => const EmptyState(
          icon: Icons.timeline,
          title: '时间线读不出来',
          message: '数据暂时读不出来，返回后再试一次。',
        ),
        data: (List<TimelineDay> days) {
          if (days.isEmpty) {
            return const EmptyState(
              icon: Icons.timeline,
              title: '还没有作答记录',
              message: '做过或判过的题都会出现在这里，按天归档。',
            );
          }
          final List<Widget> items = _buildItems(days);
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(recordsTimelineProvider);
              await ref.read(recordsTimelineProvider.future);
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                ShqSpace.lg,
                ShqSpace.md,
                ShqSpace.xl,
                ShqSpace.huge,
              ),
              itemCount: items.length,
              itemBuilder: (BuildContext context, int index) => items[index],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildItems(List<TimelineDay> days) {
    final List<Widget> items = <Widget>[];
    final DateTime today = DateTime.now();
    for (int d = 0; d < days.length; d += 1) {
      final TimelineDay day = days[d];
      items.add(
        _RailItem(
          first: d == 0,
          dot: true,
          child: _DayHeader(day: day, today: today, mode: _mode),
        ),
      );
      if (_mode == _TimelineMode.byWorkbook) {
        for (final TimelineWorkbook workbook in day.workbooks) {
          if (workbook.isRedo) {
            // 组卷 / 重刷：点开是"展开这条记录"，不跳去重刷答题卡。
            final bool expanded = _expandedGroups.contains(workbook.workbookId);
            items.add(
              _RailItem(
                child: _WorkbookCard(
                  workbook: workbook,
                  expanded: expanded,
                  onOpen: () => setState(() {
                    if (!expanded) {
                      _expandedGroups.add(workbook.workbookId);
                    } else {
                      _expandedGroups.remove(workbook.workbookId);
                    }
                  }),
                  onMenu: () => unawaited(_openWorkbookMenu(workbook)),
                ),
              ),
            );
            if (expanded) {
              for (final AnswerLogEntry entry in workbook.entries) {
                items.add(
                  _RailItem(
                    child: _QuestionRow(
                      entry: entry,
                      sourceDeleted: false,
                      // 重刷记录不跳去原卷：它已经在收藏夹/组卷里了。
                      onTap: () => _toast('这是重刷记录，笔迹在收藏夹里'),
                      onLongPress: () =>
                          unawaited(_openQuestionMenu(entry, workbook)),
                    ),
                  ),
                );
              }
            }
            continue;
          }
          items.add(
            _RailItem(
              child: _WorkbookCard(
                workbook: workbook,
                onOpen: () => _openWorkbook(workbook),
                onMenu: () => unawaited(_openWorkbookMenu(workbook)),
              ),
            ),
          );
        }
      } else {
        for (final TimelineWorkbook workbook in day.workbooks) {
          items.add(
            _RailItem(
              child: _WorkbookHint(
                workbook: workbook,
                onTap: () => _openWorkbook(workbook),
              ),
            ),
          );
          for (final AnswerLogEntry entry in workbook.entries) {
            items.add(
              _RailItem(
                child: _QuestionRow(
                  entry: entry,
                  sourceDeleted: workbook.sourceDeleted,
                  onTap: () => _openQuestion(entry, workbook),
                  onLongPress: () => unawaited(_openQuestionMenu(entry, workbook)),
                ),
              ),
            );
          }
        }
      }
    }
    return items;
  }

  // ── 回原卷 ─────────────────────────────────────────────────────────────

  void _openWorkbook(TimelineWorkbook workbook) {
    if (workbook.sourceDeleted) {
      _toast('原卷已删除，无法回到作答位置');
      return;
    }
    // 该天的第一题（`entries` 已按时间倒序，取 last 即最早那道）。
    final String questionId = workbook.entries.last.questionId;
    _pushReader(workbook.workbookId, questionId);
  }

  void _openQuestion(AnswerLogEntry entry, TimelineWorkbook workbook) {
    if (workbook.sourceDeleted) {
      _toast('原卷已删除，无法回到作答位置');
      return;
    }
    _pushReader(entry.workbookId, entry.questionId);
  }

  void _pushReader(String workbookId, String questionId) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.reader,
        arguments: ReaderRouteArgs(
          workbookId: workbookId,
          initialQuestionId: questionId,
        ),
      ),
    );
  }

  // ── 长按菜单（与书架/收藏夹同一套动作，不另造） ─────────────────────────

  Future<void> _openWorkbookMenu(TimelineWorkbook group) async {
    if (group.sourceDeleted) {
      _toast('原卷已删除，只能保留这条记录');
      return;
    }
    final WorkbookDao dao = ref.read(workbookDaoProvider);
    final Workbook? workbook = await dao.byId(group.workbookId);
    if (workbook == null || !mounted) {
      _toast('原卷已删除');
      return;
    }
    final _WorkbookAction? action = await showModalBottomSheet<_WorkbookAction>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(context, _WorkbookAction.rename),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移动到文件夹'),
              onTap: () => Navigator.pop(context, _WorkbookAction.move),
            ),
            ListTile(
              leading: const Icon(Icons.auto_stories_outlined),
              title: const Text('在书架中查看'),
              onTap: () => Navigator.pop(context, _WorkbookAction.shelf),
            ),
            const SizedBox(height: ShqSpace.sm),
          ],
        ),
      ),
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case _WorkbookAction.rename:
        final String? title = await showRenameDialog(
          context,
          initialTitle: workbook.title,
          dialogTitle: '重命名试卷',
        );
        if (title == null || !mounted) {
          return;
        }
        await dao.rename(workbook.id, title);
        // 记录表里的卷名快照同步（活库读不到时才用快照，见 groupTimeline）。
        await ref
            .read(recordServiceProvider)
            .renameWorkbook(workbook.id, title);
        ref.invalidate(bookshelfProvider);
        ref.invalidate(recordsTimelineProvider);
      case _WorkbookAction.move:
        final List<ShelfFolder> folders = await ref
            .read(folderDaoProvider)
            .list();
        if (!mounted) {
          return;
        }
        final String? folderId = await showFolderPicker(
          context,
          folders: folders,
          currentId: workbook.folderId,
        );
        if (folderId == null || !mounted) {
          return;
        }
        await dao.setFolderId(workbook.id, folderId);
        ref.invalidate(bookshelfProvider);
      case _WorkbookAction.shelf:
        ref.read(shellTabProvider.notifier).select(kBookshelfTab);
        Navigator.of(context).popUntil((Route<void> route) => route.isFirst);
    }
  }

  Future<void> _openQuestionMenu(
    AnswerLogEntry entry,
    TimelineWorkbook group,
  ) async {
    final _QuestionAction? action = await showModalBottomSheet<_QuestionAction>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: Text(
                '第 ${questionLabelText(entry.label)} 题 · ${group.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: Text(
                '${entry.source.label} · ${RecordTime.clock(entry.localTime)}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.my_location_outlined),
              title: const Text('在卷中定位'),
              enabled: !group.sourceDeleted,
              onTap: () => Navigator.pop(context, _QuestionAction.locate),
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('复制题号与卷名'),
              onTap: () => Navigator.pop(context, _QuestionAction.copy),
            ),
            const SizedBox(height: ShqSpace.sm),
          ],
        ),
      ),
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case _QuestionAction.locate:
        _openQuestion(entry, group);
      case _QuestionAction.copy:
        await Clipboard.setData(
          ClipboardData(
            text: '${group.title} 第 ${questionLabelText(entry.label)} 题',
          ),
        );
        if (mounted) {
          _toast('已复制');
        }
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1600),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

enum _WorkbookAction { rename, move, shelf }

enum _QuestionAction { locate, copy }

/// 时间线左侧的轴：一条 1px 竖线 + 分组圆点。
class _RailItem extends StatelessWidget {
  const _RailItem({required this.child, this.dot = false, this.first = false});

  final Widget child;

  /// 分组头画圆点（时间线的"刻度"）。
  final bool dot;

  /// 第一项不画上方的线（避免顶部悬空一截）。
  final bool first;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Stack(
      children: <Widget>[
        Positioned(
          left: 9,
          top: first ? 18 : 0,
          bottom: 0,
          child: Container(width: 1, color: scheme.outlineVariant),
        ),
        if (dot)
          Positioned(
            left: 4,
            top: 8,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: scheme.surface,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.primary, width: 2),
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.only(left: 24, top: dot ? ShqSpace.md : 0),
          child: child,
        ),
      ],
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.day,
    required this.today,
    required this.mode,
  });

  final TimelineDay day;
  final DateTime today;
  final _TimelineMode mode;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: ShqSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Text(
            RecordTime.relativeDay(day.day, today: today),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: ShqSpace.xs),
          Text(
            RecordTime.weekday(day.day),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            '${day.questions} 题 · ${day.workbookCount} 卷',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 按试卷：一天一张卷卡（判定色带 + 时间范围）。
class _WorkbookCard extends StatelessWidget {
  const _WorkbookCard({
    required this.workbook,
    required this.onOpen,
    required this.onMenu,
    this.expanded = false,
  });

  final TimelineWorkbook workbook;
  final VoidCallback onOpen;
  final VoidCallback onMenu;

  /// 组卷/重刷卡：是否已展开记录列表。
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool deleted = workbook.sourceDeleted;
    final String span = _span(workbook.firstAt, workbook.lastAt);

    return Padding(
      padding: const EdgeInsets.only(bottom: ShqSpace.md),
      child: Pressable(
        onTap: onOpen,
        onLongPress: onMenu,
        scale: 0.995,
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.md,
            ShqSpace.md,
            ShqSpace.sm,
            ShqSpace.md,
          ),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(ShqRadius.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            workbook.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: deleted ? scheme.outline : scheme.onSurface,
                            ),
                          ),
                        ),
                        if (deleted) ...<Widget>[
                          const SizedBox(width: ShqSpace.xs),
                          Text(
                            '原卷已删',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.outline,
                            ),
                          ),
                        ],
                        if (workbook.origin == RecordOrigin.set) ...<Widget>[
                          const SizedBox(width: ShqSpace.xs),
                          _OriginBadge(
                            text: workbook.originTitle.isEmpty
                                ? '组卷'
                                : '组卷 · ${workbook.originTitle}',
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: ShqSpace.sm),
                    _VerdictStrip(entries: workbook.entries),
                    const SizedBox(height: ShqSpace.sm),
                    Row(
                      children: <Widget>[
                        Text(
                          '${workbook.questions} 题',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          ' · ',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.outline,
                          ),
                        ),
                        const SizedBox(width: ShqSpace.sm),
                        Text(
                          span,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(
                deleted
                    ? Icons.link_off
                    : (workbook.isRedo
                          ? (expanded ? Icons.expand_less : Icons.expand_more)
                          : Icons.chevron_right),
                size: 20,
                color: scheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _span(DateTime first, DateTime last) {
    final String a = RecordTime.clock(first);
    final String b = RecordTime.clock(last);
    return a == b ? a : '$a – $b';
  }
}

/// 来源角标（组卷 / 重刷）。
class _OriginBadge extends StatelessWidget {
  const _OriginBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ShqRadius.pill),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.primary,
          fontSize: 10,
        ),
      ),
    );
  }
}

/// 逐题色带：一格一题，按判定上色（对绿 / 错红 / 待判黄 / 未判灰）。
///
/// 这是时间线独有的"答题心电图"：不用读数字就能看出那片区域红不红。
class _VerdictStrip extends StatelessWidget {
  const _VerdictStrip({required this.entries});

  final List<AnswerLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<AnswerLogEntry> ordered = entries.reversed.toList(growable: false);
    return SizedBox(
      height: 16,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final AnswerLogEntry entry in ordered)
            Container(
              width: 5,
              margin: const EdgeInsets.only(right: 3),
              decoration: BoxDecoration(
                color: switch (entry.verdict) {
                  AnswerVerdict.correct => ShqPalette.correct,
                  AnswerVerdict.wrong => ShqPalette.wrong,
                  AnswerVerdict.pending => ShqPalette.unclear,
                  AnswerVerdict.none => scheme.surfaceContainerHighest,
                },
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
        ],
      ),
    );
  }
}

/// 按题目模式下的卷名小标（轻量，不做成卡片）。
class _WorkbookHint extends StatelessWidget {
  const _WorkbookHint({required this.workbook, required this.onTap});

  final TimelineWorkbook workbook;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: ShqSpace.xs, bottom: ShqSpace.xs),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: <Widget>[
            Icon(
              Icons.auto_stories_outlined,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: ShqSpace.xs),
            Flexible(
              child: Text(
                workbook.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (workbook.sourceDeleted) ...<Widget>[
              const SizedBox(width: ShqSpace.xs),
              Text(
                '原卷已删',
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
}

class _QuestionRow extends StatelessWidget {
  const _QuestionRow({
    required this.entry,
    required this.sourceDeleted,
    required this.onTap,
    required this.onLongPress,
  });

  final AnswerLogEntry entry;
  final bool sourceDeleted;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: ShqSpace.sm),
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        scale: 0.995,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: ShqSpace.md,
            vertical: ShqSpace.sm,
          ),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(ShqRadius.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: <Widget>[
              Container(
                constraints: const BoxConstraints(minWidth: 34),
                padding: const EdgeInsets.symmetric(
                  horizontal: ShqSpace.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(ShqRadius.pill),
                ),
                child: Text(
                  questionLabelText(entry.label),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: sourceDeleted ? scheme.outline : scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: ShqSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '第 ${questionLabelText(entry.label)} 题 · '
                      '${questionKindLabel(entry.kind)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: sourceDeleted ? scheme.outline : scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${RecordTime.clock(entry.localTime)} · ${entry.source.label}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: ShqSpace.sm),
              GradeDot(verdict: entry.verdict, size: 10),
            ],
          ),
        ),
      ),
    );
  }
}
