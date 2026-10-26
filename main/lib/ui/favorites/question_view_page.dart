import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/favorite/favorite_store.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/model/redo_attempt.dart';
import 'package:shuaqi/domain/reader/panel_metrics.dart';
import 'package:shuaqi/domain/region/answer.dart';
import 'package:shuaqi/infra/db/dao/answer_log_dao.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/favorite_providers.dart';
import 'package:shuaqi/state/panel_width_provider.dart';
import 'package:shuaqi/ui/favorites/favorite_ai_panel.dart';
import 'package:shuaqi/ui/favorites/favorite_card.dart';
import 'package:shuaqi/ui/favorites/favorite_image.dart';
import 'package:shuaqi/ui/favorites/favorite_redo_page.dart';
import 'package:shuaqi/ui/favorites/favorite_tag_editor.dart';
import 'package:shuaqi/ui/panel/grade_dot.dart';
import 'package:shuaqi/ui/panel/panel_resize_handle.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 进入看题页的入参。
class QuestionViewArgs {
  const QuestionViewArgs({required this.favoriteId});

  final String favoriteId;
}

/// 收藏看题页（T8.3）：单独查看一道收藏题的完整信息。
///
/// 内容（自上而下）：题面图 → 我的作答（收藏时）→ 重刷 → 判定与参考答案。
/// 动作：问 AI（顶栏按钮 → 右侧面板，与阅读器题目面板同一套）、重刷、
/// 回看出处（原卷在时跳转定位）、取消收藏。原卷删除后全部走快照。
class QuestionViewPage extends ConsumerStatefulWidget {
  const QuestionViewPage({super.key, required this.favoriteId});

  final String favoriteId;

  @override
  ConsumerState<QuestionViewPage> createState() => _QuestionViewPageState();
}

class _QuestionViewPageState extends ConsumerState<QuestionViewPage> {
  Favorite? _favorite;
  QuestionGrade? _grade;
  AnswerNote? _note;
  FavoriteImage? _stem;
  FavoriteImage? _answer;
  List<RedoAttempt> _attempts = const <RedoAttempt>[];
  bool _loading = true;
  bool _aiOpen = false;

  /// 拖动中的面板宽度（null = 用全局记忆值）。
  double? _dragPanelWidth;
  double _dragStartPanelWidth = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final FavoriteStore store = ref.read(favoriteStoreProvider);
    final Favorite? favorite = await store.byId(widget.favoriteId);
    if (!mounted) {
      return;
    }
    if (favorite == null) {
      // 收藏已被删（例如别处取消收藏），直接退回。
      Navigator.of(context).pop();
      return;
    }
    final QuestionGrade? grade = await store.loadGrading(widget.favoriteId);
    final AnswerNote? note = await store.loadAnswerNote(widget.favoriteId);
    final Vault vault = ref.read(vaultProvider);
    final FavoriteImage? stem = await loadFavoriteImage(
      vault.file(VaultPaths.favoriteStem(favorite.id)),
    );
    final FavoriteImage? answer = await loadFavoriteImage(
      vault.file(VaultPaths.favoriteAnswerImg(favorite.id)),
    );
    final List<RedoAttempt> attempts = await ref
        .read(redoAttemptStoreProvider)
        .list(favorite.id);
    if (!mounted) {
      return;
    }
    setState(() {
      _favorite = favorite;
      _grade = grade;
      _note = note;
      _stem = stem;
      _answer = answer;
      _attempts = attempts;
      _loading = false;
    });
    // 老收藏的题面图只有 1024px 宽（平板铺满会发虚），迁移来的干脆没有。
    // 原卷还在就后台补一张高清的，补好直接换图、不打断阅读。
    unawaited(_upgradeStem(favorite));
  }

  /// 重新读重刷记录列表（新建/保存/删除后调用）。
  Future<void> _reloadAttempts(Favorite favorite) async {
    final List<RedoAttempt> attempts = await ref
        .read(redoAttemptStoreProvider)
        .list(favorite.id);
    if (mounted) {
      setState(() => _attempts = attempts);
    }
  }

  /// AI 判完写回快照后：刷新判定卡片与本页的收藏副本。
  Future<void> _reloadGrading() async {
    final FavoriteStore store = ref.read(favoriteStoreProvider);
    final Favorite? favorite = await store.byId(widget.favoriteId);
    final QuestionGrade? grade = await store.loadGrading(widget.favoriteId);
    if (!mounted || favorite == null) {
      return;
    }
    setState(() {
      _favorite = favorite;
      _grade = grade;
    });
  }

  /// 按需高清重渲染题面图（`favorites/<id>/stem.png` 原地升级）。
  Future<void> _upgradeStem(Favorite favorite) async {
    final Uint8List? bytes = await ref
        .read(favoriteStemServiceProvider)
        .ensure(
          favoriteId: favorite.id,
          workbookId: favorite.workbookId,
          pageIndex: favorite.pageIndex,
          rect: favorite.rect,
        );
    if (bytes == null || !mounted) {
      return;
    }
    final FavoriteImage? image = await decodeFavoriteImage(bytes);
    if (image != null && mounted) {
      setState(() => _stem = image);
    }
  }

  Future<void> _startRedo(Favorite favorite) async {
    await Navigator.of(context).pushNamed(
      AppRoutes.favoriteRedo,
      arguments: RedoArgs(
        favoriteIds: <String>[favorite.id],
        title: '第 ${favorite.label} 题',
        startNew: true,
      ),
    );
    if (mounted) {
      await _reloadAttempts(favorite);
    }
  }

  Future<void> _openAttempt(Favorite favorite, RedoAttempt attempt) async {
    await Navigator.of(context).pushNamed(
      AppRoutes.favoriteRedo,
      arguments: RedoArgs(
        favoriteIds: <String>[favorite.id],
        title: attempt.isSet
            ? '组卷 · ${attempt.setTitle}'
            : '第 ${favorite.label} 题 · 重刷',
        attemptId: attempt.id,
        isSet: attempt.isSet,
      ),
    );
    if (mounted) {
      await _reloadAttempts(favorite);
    }
  }

  Future<void> _deleteAttempt(Favorite favorite, RedoAttempt attempt) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除这次重刷？'),
        content: const Text('只删这一次重刷的笔迹与记录；收藏本身和原作答不受影响。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    await ref.read(redoAttemptStoreProvider).delete(favorite.id, attempt.id);
    try {
      await AnswerLogDao(
        ref.read(appDependenciesProvider).db.raw,
      ).deleteAttempt(attempt.id);
    } on Object {
      // 记录是旁路；删不掉也不影响删笔迹。
    }
    ref.invalidate(redoAttemptsProvider(favorite.id));
    await _reloadAttempts(favorite);
  }

  @override
  Widget build(BuildContext context) {
    final Favorite? favorite = _favorite;
    final String? latestAttemptId = _attempts.isEmpty ? null : _attempts.first.id;
    final double panelWidth = favorite != null && _aiOpen
        ? _panelWidth(context)
        : 0;
    ref.watch(panelWidthProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(favorite == null ? '收藏' : '第 ${favorite.label} 题'),
        actions: <Widget>[
          IconButton.filledTonal(
            tooltip: _aiOpen ? '收起 AI' : '问 AI',
            isSelected: _aiOpen,
            icon: const Icon(Icons.auto_awesome_outlined),
            selectedIcon: const Icon(Icons.auto_awesome),
            onPressed: favorite == null
                ? null
                : () => setState(() => _aiOpen = !_aiOpen),
          ),
          IconButton(
            tooltip: favorite?.sourceDeleted == true
                ? '原卷已删除，无法回到出处'
                : '回到出处',
            onPressed: favorite == null || favorite.sourceDeleted
                ? null
                : () => _openSource(favorite),
            icon: const Icon(Icons.open_in_new_outlined),
          ),
          IconButton(
            tooltip: '收藏操作（编辑知识点 / 取消收藏）',
            onPressed: favorite == null
                ? null
                : () => _openFavoriteActions(favorite),
            icon: Icon(
              Icons.star,
              color: Theme.of(context).colorScheme.tertiary,
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: <Widget>[
                Positioned.fill(
                  child: AnimatedPadding(
                    duration: ShqMotion.base,
                    curve: ShqMotion.curveStandard,
                    padding: EdgeInsets.only(right: panelWidth),
                    child: _Body(
                      favorite: favorite!,
                      stem: _stem,
                      answer: _answer,
                      attempts: _attempts,
                      grade: _grade,
                      note: _note,
                      onRedo: () => _startRedo(favorite),
                      onOpenAttempt: (RedoAttempt attempt) =>
                          _openAttempt(favorite, attempt),
                      onDeleteAttempt: (RedoAttempt attempt) =>
                          _deleteAttempt(favorite, attempt),
                      onEditTags: () => _editTags(favorite),
                    ),
                  ),
                ),
                if (_aiOpen)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: panelWidth,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 22,
                            offset: const Offset(-3, 0),
                          ),
                        ],
                      ),
                      child: FavoriteAiPanel(
                        key: ValueKey<String>('view-ai-${favorite.id}'),
                        favorite: favorite,
                        width: panelWidth,
                        attemptId: latestAttemptId,
                        onClose: () => setState(() => _aiOpen = false),
                        onGraded: () => unawaited(_reloadGrading()),
                      ),
                    ),
                  ),
                if (_aiOpen)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: panelWidth - 14,
                    width: 28,
                    child: PanelResizeHandle(
                      onResizeStart: _onPanelResizeStart,
                      onResize: _onPanelResize,
                      onResizeEnd: _onPanelResizeEnd,
                    ),
                  ),
              ],
            ),
    );
  }

  double _panelWidth(BuildContext context) {
    final double screen = MediaQuery.sizeOf(context).width;
    final double stored =
        _dragPanelWidth ??
        ref.read(panelWidthProvider) ??
        PanelMetrics.defaultFor(screen);
    return PanelMetrics.clampWidth(stored, screen);
  }

  void _onPanelResizeStart() {
    _dragStartPanelWidth = _panelWidth(context);
    setState(() => _dragPanelWidth = _dragStartPanelWidth);
  }

  void _onPanelResize(double totalGrow) {
    final double screen = MediaQuery.sizeOf(context).width;
    setState(() {
      _dragPanelWidth = PanelMetrics.clampWidth(
        _dragStartPanelWidth + totalGrow,
        screen,
      );
    });
  }

  void _onPanelResizeEnd() {
    final double? width = _dragPanelWidth;
    if (width == null) {
      return;
    }
    setState(() => _dragPanelWidth = null);
    ref.read(panelWidthProvider.notifier).commit(width);
  }

  void _openSource(Favorite favorite) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.reader,
        arguments: ReaderRouteArgs(
          workbookId: favorite.workbookId,
          initialQuestionId: favorite.questionId,
        ),
      ),
    );
  }

  Future<void> _openFavoriteActions(Favorite favorite) async {
    final String? action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.lg)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.sell_outlined),
              title: const Text('编辑知识点'),
              subtitle: Text(
                favorite.knowledgeTags.isEmpty
                    ? '未归纳'
                    : favorite.knowledgeTags.join('、'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(context, 'tag'),
            ),
            ListTile(
              leading: const Icon(Icons.star_border),
              title: const Text('取消收藏'),
              subtitle: const Text('只删这份收藏快照，原卷与作答不受影响'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    switch (action) {
      case 'tag':
        await _editTags(favorite);
      case 'remove':
        await _removeFavorite(favorite);
    }
  }

  Future<void> _editTags(Favorite favorite) async {
    final FavoriteStore store = ref.read(favoriteStoreProvider);
    final List<Favorite> all = await store.list();
    final List<String> suggestions = <String>{
      for (final Favorite item in all) ...item.knowledgeTags,
    }.toList();
    if (!mounted) {
      return;
    }
    final List<String>? tags = await showFavoriteTagEditor(
      context,
      initial: favorite.knowledgeTags,
      suggestions: suggestions,
    );
    if (tags == null || !mounted) {
      return;
    }
    await store.updateKnowledgeTags(favorite.id, tags);
    await store.touchLastTagAt();
    ref.invalidate(favoritesProvider);
    final Favorite? updated = await store.byId(favorite.id);
    if (!mounted) {
      return;
    }
    setState(() => _favorite = updated ?? favorite);
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(tags.isEmpty ? '已设为未归纳' : '知识点已更新：${tags.join('、')}'),
            duration: const Duration(milliseconds: 1800),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  Future<void> _removeFavorite(Favorite favorite) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('取消收藏'),
        content: const Text('这道题会从收藏夹移除（快照一并删除），确定吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await ref.read(favoriteStoreProvider).remove(favorite.id);
    ref.invalidate(favoritesProvider);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.favorite,
    required this.stem,
    required this.answer,
    required this.attempts,
    required this.grade,
    required this.note,
    required this.onRedo,
    required this.onOpenAttempt,
    required this.onDeleteAttempt,
    required this.onEditTags,
  });

  final Favorite favorite;
  final FavoriteImage? stem;
  final FavoriteImage? answer;
  final List<RedoAttempt> attempts;
  final QuestionGrade? grade;
  final AnswerNote? note;
  final VoidCallback onRedo;
  final ValueChanged<RedoAttempt> onOpenAttempt;
  final ValueChanged<RedoAttempt> onDeleteAttempt;
  final VoidCallback onEditTags;

  @override
  Widget build(BuildContext context) {
    final double screenHeight = MediaQuery.sizeOf(context).height;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.md,
        ShqSpace.lg,
        ShqSpace.xxl * 2,
      ),
      children: <Widget>[
        if (favorite.sourceDeleted) const _DeletedBanner(),
        _MetaHeader(
          favorite: favorite,
          verdict: grade?.verdict,
          onRedo: onRedo,
          onEditTags: onEditTags,
        ),
        _Section(
          title: '题面',
          child: FavoriteImageView(
            image: stem,
            title: '第 ${favorite.label} 题题面',
            maxHeight: screenHeight * 0.56,
            emptyHint: favorite.sourceDeleted
                ? '原卷已删除，收藏时也没有存下题面图'
                : '题面图暂时无法生成，可回原卷查看',
          ),
        ),
        _Section(
          title: '我的作答（收藏时）',
          child: FavoriteImageView(
            image: answer,
            title: '第 ${favorite.label} 题我的作答',
            maxHeight: screenHeight * 0.42,
            emptyHint: favorite.sourceDeleted
                ? '收藏时没有作答笔迹'
                : '收藏时没有作答笔迹，点「重刷」可以现在写一遍',
          ),
        ),
        _RedoHistorySection(
          favorite: favorite,
          attempts: attempts,
          onRedo: onRedo,
          onOpen: onOpenAttempt,
          onDelete: onDeleteAttempt,
        ),
        _Section(
          title: '判定与参考答案',
          child: _VerdictCard(
            grade: grade,
            note: note,
            verdict: favorite.verdict,
          ),
        ),
      ],
    );
  }
}

class _RedoHistorySection extends StatelessWidget {
  const _RedoHistorySection({
    required this.favorite,
    required this.attempts,
    required this.onRedo,
    required this.onOpen,
    required this.onDelete,
  });

  final Favorite favorite;
  final List<RedoAttempt> attempts;
  final VoidCallback onRedo;
  final ValueChanged<RedoAttempt> onOpen;
  final ValueChanged<RedoAttempt> onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: ShqSpace.lg),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.md,
            ShqSpace.md,
            ShqSpace.md,
            ShqSpace.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    '重刷记录',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: ShqSpace.sm),
                  Text(
                    '${attempts.length} 次',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onRedo,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('重刷这道题'),
                  ),
                ],
              ),
              if (attempts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: ShqSpace.md,
                    horizontal: ShqSpace.xs,
                  ),
                  child: Text(
                    '还没有重刷记录。点「重刷这道题」会打开空白答题卡，'
                    '退出时问你是否保存这一次；原作答与收藏都不受影响。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                )
              else
                for (final RedoAttempt attempt in attempts)
                  _AttemptRow(
                    attempt: attempt,
                    onOpen: () => onOpen(attempt),
                    onDelete: () => onDelete(attempt),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttemptRow extends StatelessWidget {
  const _AttemptRow({
    required this.attempt,
    required this.onOpen,
    required this.onDelete,
  });

  final RedoAttempt attempt;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String title = attempt.isDraft
        ? '未保存的重刷'
        : attempt.isSet
        ? '组卷 · ${attempt.setTitle.isEmpty ? '未命名组卷' : attempt.setTitle}'
        : '单题重刷';
    final String time = _formatAttemptTime(attempt.updatedAtTime);
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(ShqRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ShqSpace.xs,
          vertical: ShqSpace.sm,
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: attempt.isDraft
                    ? scheme.tertiaryContainer
                    : scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(ShqRadius.sm),
              ),
              child: Icon(
                attempt.isDraft ? Icons.edit_note : Icons.history,
                size: 18,
                color: attempt.isDraft
                    ? scheme.onTertiaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: ShqSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (attempt.isDraft) ...<Widget>[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.tertiary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(ShqRadius.pill),
                          ),
                          child: Text(
                            '未保存',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.tertiary,
                              fontSize: 9.5,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$time · ${attempt.paperPages} 张纸'
                    '${attempt.paperSummary.isEmpty ? '' : ' · ${attempt.paperSummary}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '这一次重刷',
              onSelected: (String value) {
                if (value == 'delete') {
                  onDelete();
                }
              },
              itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Text('删除这次记录'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatAttemptTime(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}

/// 顶部元信息：题号/题型/卷名/知识点 + 重刷入口，一眼知道"这是什么题、从哪来"。
class _MetaHeader extends StatelessWidget {
  const _MetaHeader({
    required this.favorite,
    required this.verdict,
    required this.onRedo,
    required this.onEditTags,
  });

  final Favorite favorite;
  final AnswerVerdict? verdict;
  final VoidCallback onRedo;
  final VoidCallback onEditTags;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: ShqSpace.md),
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.md,
        ShqSpace.sm,
        ShqSpace.md,
        ShqSpace.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              GradeDot(verdict: verdict ?? favorite.verdict, size: 11),
              const SizedBox(width: ShqSpace.xs),
              Text(
                favoriteKindLabel(favorite.kind),
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(width: ShqSpace.sm),
              Expanded(
                child: Text(
                  favorite.workbookTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (favorite.sourceDeleted)
                Text(
                  ' · 原卷已删',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                  ),
                ),
              const SizedBox(width: ShqSpace.sm),
              // 重刷是本页的主行动：用实心主色按钮，别让它藏在图标里。
              FilledButton.icon(
                onPressed: onRedo,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ShqSpace.lg,
                    vertical: ShqSpace.sm,
                  ),
                  minimumSize: const Size(0, 40),
                  textStyle: theme.textTheme.titleSmall,
                ),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('重刷'),
              ),
            ],
          ),
          const SizedBox(height: ShqSpace.xs),
          Wrap(
            spacing: ShqSpace.xs,
            runSpacing: ShqSpace.xxs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              for (final String tag in favorite.knowledgeTags)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ShqSpace.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(ShqRadius.pill),
                  ),
                  child: Text(
                    tag,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                      fontSize: 10.5,
                    ),
                  ),
                ),
              // 看题页也要能改知识点：一眼可见的入口，不必先回收藏夹长按。
              ActionChip(
                avatar: const Icon(Icons.add, size: 14),
                label: Text(favorite.knowledgeTags.isEmpty ? '添加知识点' : '编辑'),
                onPressed: onEditTags,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeletedBanner extends StatelessWidget {
  const _DeletedBanner();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: ShqSpace.md),
      padding: const EdgeInsets.symmetric(
        horizontal: ShqSpace.md,
        vertical: ShqSpace.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(ShqRadius.md),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Text(
              '原卷已删除，以下为收藏时的快照。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: ShqSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: ShqSpace.sm),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// 快照图片（题面/作答）已抽到 `favorite_image.dart` 的 [FavoriteImageView]
/// （T8.3b：支持按需高清重渲染后热替换 + 点开全屏缩放）。

class _VerdictCard extends StatelessWidget {
  const _VerdictCard({
    required this.grade,
    required this.note,
    required this.verdict,
  });

  final QuestionGrade? grade;
  final AnswerNote? note;
  final AnswerVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AnswerVerdict shown = grade?.verdict ?? verdict;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              GradeDot(verdict: shown),
              const SizedBox(width: ShqSpace.sm),
              Text(
                gradeLabel(shown),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (note != null && note!.text.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: ShqSpace.sm),
            Text(
              note!.text,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          if (grade != null && grade!.note.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: ShqSpace.sm),
            Text(
              '依据：${grade!.note}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

