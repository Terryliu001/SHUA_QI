import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/favorite_set_plan.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/favorite_providers.dart';
import 'package:shuaqi/ui/favorites/favorite_card.dart';
import 'package:shuaqi/ui/favorites/favorite_redo_page.dart';
import 'package:shuaqi/ui/favorites/question_view_page.dart';
import 'package:shuaqi/ui/panel/grade_dot.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/empty_state.dart';

/// 进入组卷详情页的入参。
class FavoriteSetArgs {
  const FavoriteSetArgs({required this.setId});

  final String setId;
}

/// 组卷详情（T8.4）：一份命名题集的成员、顺序与入口。
///
/// 一条主线：**组卷只活在收藏夹**，不进书架、不改变原卷；
/// 「开始连刷」把卷内题序原样交给 [FavoriteRedoPage]，一题一题翻。
class FavoriteSetPage extends ConsumerStatefulWidget {
  const FavoriteSetPage({super.key, required this.setId});

  final String setId;

  @override
  ConsumerState<FavoriteSetPage> createState() => _FavoriteSetPageState();
}

class _FavoriteSetPageState extends ConsumerState<FavoriteSetPage> {
  FavoriteSet? _set;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final FavoriteSet? set = await ref
        .read(favoriteStoreProvider)
        .setById(widget.setId);
    if (!mounted) {
      return;
    }
    setState(() {
      _set = set;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Favorite>> async = ref.watch(
      favoriteSetItemsProvider(widget.setId),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(_set?.displayName ?? '题集'),
        actions: <Widget>[
          IconButton(
            tooltip: '添加题目',
            onPressed: _set == null ? null : () => unawaited(_addQuestions()),
            icon: const Icon(Icons.playlist_add),
          ),
          IconButton(
            tooltip: '重命名',
            onPressed: _set == null ? null : () => unawaited(_rename()),
            icon: const Icon(Icons.drive_file_rename_outline),
          ),
          IconButton(
            tooltip: '删除题集',
            onPressed: _set == null ? null : () => unawaited(_delete()),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object error, StackTrace? stack) => const EmptyState(
                icon: Icons.folder_off_outlined,
                title: '题集加载失败',
                message: '数据暂时读不出来，稍后再试。',
              ),
              data: (List<Favorite> items) => _body(items),
            ),
    );
  }

  Widget _body(List<Favorite> items) {
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.playlist_add_outlined,
        title: '这份题集还是空的',
        message: '回收藏夹长按题目「加入组卷」，或多选之后「加入组卷」。',
      );
    }
    return Column(
      children: <Widget>[
        _SetHeader(set: _set, count: items.length),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(
              ShqSpace.lg,
              0,
              ShqSpace.lg,
              ShqSpace.xxl,
            ),
            itemCount: items.length,
            buildDefaultDragHandles: false,
            onReorderItem: (int oldIndex, int newIndex) =>
                unawaited(_reorder(items, oldIndex, newIndex)),
            itemBuilder: (BuildContext context, int index) {
              final Favorite favorite = items[index];
              // 长按整行就能拖：比只抓右侧把手好按（平板手指粗）。
              return ReorderableDelayedDragStartListener(
                key: ValueKey<String>(favorite.id),
                index: index,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: ShqSpace.sm),
                  child: _SetItemRow(
                    index: index,
                    favorite: favorite,
                    onTap: () => _openRedo(items, index),
                    onOpenQuestion: () => _openQuestion(items[index]),
                    onRemove: () => unawaited(_remove(items[index])),
                  ),
                ),
              );
            },
          ),
        ),
        _StartBar(items: items, onStart: () => _openRedo(items, 0)),
      ],
    );
  }

  void _openRedo(List<Favorite> items, int index) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.favoriteRedo,
        arguments: RedoArgs(
          favoriteIds: <String>[for (final Favorite f in items) f.id],
          title: _set?.displayName ?? '连刷',
          setId: widget.setId,
          initialIndex: index,
        ),
      ),
    );
  }

  void _openQuestion(Favorite favorite) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.favoriteQuestion,
        arguments: QuestionViewArgs(favoriteId: favorite.id),
      ),
    );
  }

  Future<void> _rename() async {
    final FavoriteSet? set = _set;
    if (set == null) {
      return;
    }
    final TextEditingController controller = TextEditingController(
      text: set.displayName,
    );
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('重命名题集'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '如：三角函数易错 10 题'),
          onSubmitted: (String value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(context, value.trim());
            }
          },
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final String value = controller.text.trim();
              if (value.isNotEmpty) {
                Navigator.pop(context, value);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) {
      return;
    }
    await ref.read(favoriteStoreProvider).renameSet(set.id, name);
    if (!mounted) {
      return;
    }
    await _load();
    ref.invalidate(favoriteSetsProvider);
  }

  Future<void> _delete() async {
    final FavoriteSet? set = _set;
    if (set == null) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除题集'),
        content: Text('「${set.displayName}」会被删除。题目本身仍留在收藏夹，不影响收藏。'),
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
    if (confirmed != true || !mounted) {
      return;
    }
    await ref.read(favoriteStoreProvider).deleteSet(set.id);
    ref.invalidate(favoriteSetsProvider);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _remove(Favorite favorite) async {
    await ref.read(favoriteStoreProvider).removeFromSet(widget.setId, favorite.id);
    ref.invalidate(favoriteSetItemsProvider(widget.setId));
    ref.invalidate(favoriteSetsProvider);
    unawaited(_load());
    if (mounted) {
      _tip('已移出题集（题目仍在收藏夹）');
    }
  }

  /// 长按拖动后的新顺序：写回 sort，连刷按这个顺序走。
  ///
  /// `onReorderItem` 已经替我们扣掉"移出后索引左移一位"，这里直接落位。
  Future<void> _reorder(
    List<Favorite> items,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex < 0 || oldIndex >= items.length) {
      return;
    }
    final int target = newIndex.clamp(0, items.length - 1);
    if (target == oldIndex) {
      return;
    }
    final List<String> ids = <String>[
      for (final Favorite favorite in items) favorite.id,
    ];
    final String moved = ids.removeAt(oldIndex);
    ids.insert(target, moved);
    await ref.read(favoriteStoreProvider).reorderSet(widget.setId, ids);
    ref.invalidate(favoriteSetItemsProvider(widget.setId));
    ref.invalidate(favoriteSetsProvider);
    unawaited(_load());
    if (mounted) {
      _tip('顺序已更新 · 连刷按新顺序');
    }
  }

  /// 从收藏夹里挑题加入本卷（不必先回收藏夹多选）。
  ///
  /// 已在卷内的题会置灰并标「已在题集」，避免"加了却看不出加没加"。
  Future<void> _addQuestions() async {
    final List<Favorite> all = await ref.read(favoritesProvider.future);
    if (!mounted) {
      return;
    }
    if (all.isEmpty) {
      _tip('收藏夹里还没有题');
      return;
    }
    final List<Favorite> members = await ref.read(
      favoriteSetItemsProvider(widget.setId).future,
    );
    if (!mounted) {
      return;
    }
    final Set<String> inSet = <String>{
      for (final Favorite favorite in members) favorite.id,
    };
    final Set<String> selected = <String>{};
    final List<String>? picked = await showDialog<List<String>>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => AlertDialog(
          title: const Text('添加题目'),
          content: SizedBox(
            width: double.maxFinite,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: all.length,
                itemBuilder: (BuildContext context, int index) {
                  final Favorite favorite = all[index];
                  final bool already = inSet.contains(favorite.id);
                  return CheckboxListTile(
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: already || selected.contains(favorite.id),
                    onChanged: already
                        ? null
                        : (bool? value) => setState(() {
                            if (value == true) {
                              selected.add(favorite.id);
                            } else {
                              selected.remove(favorite.id);
                            }
                          }),
                    title: Text('第 ${favorite.label} 题'),
                    subtitle: Text(
                      already
                          ? '${favorite.workbookTitle} · 已在题集'
                          : favorite.workbookTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () =>
                        Navigator.pop(context, selected.toList(growable: false)),
              child: Text('加入 ${selected.length} 题'),
            ),
          ],
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) {
      return;
    }
    final int added = await ref
        .read(favoriteStoreProvider)
        .addToSet(widget.setId, picked);
    ref.invalidate(favoriteSetItemsProvider(widget.setId));
    ref.invalidate(favoriteSetsProvider);
    // 成员变了，卷头的题数/更新时间要跟着变（本地 _set 是进页面时读的）。
    unawaited(_load());
    if (mounted) {
      _tip(added == 0 ? '这些题已经在题集里了' : '已加入 $added 题');
    }
  }

  void _tip(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1800),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

class _SetHeader extends StatelessWidget {
  const _SetHeader({required this.set, required this.count});

  final FavoriteSet? set;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.sm,
        ShqSpace.lg,
        ShqSpace.md,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.playlist_play, size: 18, color: scheme.primary),
          const SizedBox(width: ShqSpace.sm),
          Text(
            '$count 题',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Text(
              set == null ? '' : '${relativeDay(set!.updatedAt, now)}更新',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            '长按拖动调整顺序',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

class _SetItemRow extends ConsumerWidget {
  const _SetItemRow({
    required this.index,
    required this.favorite,
    required this.onTap,
    required this.onOpenQuestion,
    required this.onRemove,
  });

  final int index;
  final Favorite favorite;
  final VoidCallback onTap;
  final VoidCallback onOpenQuestion;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final File stem = ref
        .watch(vaultProvider)
        .file(VaultPaths.favoriteStem(favorite.id));
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(ShqRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // 长按留给「拖动排序」（外层 ReorderableDelayedDragStartListener）；
        // 菜单改由行尾的 ⋯ 承担，两个长按不抢手势。
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(ShqSpace.sm),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 26,
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: ShqSpace.xs),
              ClipRRect(
                borderRadius: BorderRadius.circular(ShqRadius.sm),
                child: ColoredBox(
                  color: ShqPaper.base,
                  child: SizedBox(
                    width: 72,
                    height: 52,
                    child: Image.file(
                      stem,
                      fit: BoxFit.contain,
                      errorBuilder:
                          (
                            BuildContext context,
                            Object error,
                            StackTrace? stackTrace,
                          ) => Center(
                            child: Text(
                              '第 ${favorite.label} 题',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: ShqSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '第 ${favorite.label} 题',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          favoriteKindLabel(favorite.kind),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            favorite.workbookTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (favorite.sourceDeleted)
                          Text(
                            ' · 原卷已删',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 10.5,
                              color: scheme.outline,
                            ),
                          ),
                      ],
                    ),
                    if (favorite.knowledgeTags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        favorite.knowledgeTags.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: ShqSpace.xs),
              GradeDot(verdict: favorite.verdict, size: 11),
              Icon(
                Icons.drag_indicator,
                size: 17,
                color: scheme.outlineVariant,
              ),
              IconButton(
                tooltip: '更多（看题 / 从这题开始刷 / 移出）',
                onPressed: () => _menu(context),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 34,
                ),
                icon: const Icon(Icons.more_vert, size: 18),
              ),
              IconButton(
                tooltip: '移出题集',
                onPressed: onRemove,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 34,
                ),
                icon: const Icon(Icons.remove_circle_outline, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context) async {
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
              leading: const Icon(Icons.play_arrow_outlined),
              title: const Text('从这题开始刷'),
              onTap: () => Navigator.pop(context, 'redo'),
            ),
            ListTile(
              leading: const Icon(Icons.visibility_outlined),
              title: const Text('看这道题'),
              onTap: () => Navigator.pop(context, 'view'),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('移出题集'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (action == 'redo') {
      onTap();
    } else if (action == 'view') {
      onOpenQuestion();
    } else if (action == 'remove') {
      onRemove();
    }
  }
}

/// 底部主按钮：开始连刷。
class _StartBar extends StatelessWidget {
  const _StartBar({required this.items, required this.onStart});

  final List<Favorite> items;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.sm,
        ShqSpace.lg,
        ShqSpace.md,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '共 ${items.length} 题 · 从头开始',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            FilledButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.play_arrow, size: 20),
              label: const Text('开始连刷'),
            ),
          ],
        ),
      ),
    );
  }
}
