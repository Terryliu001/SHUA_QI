import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/state/favorite_providers.dart';
import 'package:shuaqi/ui/favorites/favorite_card.dart';
import 'package:shuaqi/ui/favorites/favorite_redo_page.dart';
import 'package:shuaqi/ui/favorites/question_view_page.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/empty_state.dart';

/// 进入「某一卷的收藏」的入参。
class FavoriteWorkbookArgs {
  const FavoriteWorkbookArgs({required this.workbookId, required this.title});

  final String workbookId;
  final String title;
}

/// 收藏夹「按试卷」点开后的卷内页（058）。
///
/// 只做一件事：把这一卷的收藏题按更新时间倒序铺开，点开看题、长按重刷/改知识点/取消收藏。
/// 卷名以**快照**为准（原卷已删时也有名字）；改名在收藏夹外层菜单里做（与书架双向同步）。
class FavoriteWorkbookPage extends ConsumerStatefulWidget {
  const FavoriteWorkbookPage({
    super.key,
    required this.workbookId,
    required this.title,
  });

  final String workbookId;
  final String title;

  @override
  ConsumerState<FavoriteWorkbookPage> createState() =>
      _FavoriteWorkbookPageState();
}

class _FavoriteWorkbookPageState extends ConsumerState<FavoriteWorkbookPage> {
  List<Favorite> _items = <Favorite>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final List<Favorite> items = await ref
        .read(favoriteStoreProvider)
        .listOfWorkbook(widget.workbookId);
    if (!mounted) {
      return;
    }
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  String get _title =>
      _items.isEmpty ? widget.title : _items.first.workbookTitle;

  bool get _sourceDeleted =>
      _items.isNotEmpty && _items.first.sourceDeleted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
            Text(
              '${_items.length} 道收藏'
              '${_sourceDeleted ? ' · 原卷已删' : ''}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? const EmptyState(
              icon: Icons.bookmarks_outlined,
              title: '这一卷还没有收藏',
              message: '在阅读器里选中题目收藏，就会出现在这里。',
            )
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(
                ShqSpace.md,
                ShqSpace.md,
                ShqSpace.md,
                ShqSpace.xxl,
              ),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: ShqSpace.sm,
                crossAxisSpacing: ShqSpace.sm,
                childAspectRatio: 0.92,
              ),
              itemCount: _items.length,
              itemBuilder: (BuildContext context, int index) {
                final Favorite favorite = _items[index];
                return FavoriteCard(
                  favorite: favorite,
                  onTap: () => _open(favorite),
                  onLongPress: () => unawaited(_openMenu(favorite)),
                );
              },
            ),
    );
  }

  void _open(Favorite favorite) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.favoriteQuestion,
        arguments: QuestionViewArgs(favoriteId: favorite.id),
      ),
    );
  }

  Future<void> _openMenu(Favorite favorite) async {
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
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重刷这道题'),
              onTap: () => Navigator.pop(context, 'redo'),
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_remove_outlined),
              title: const Text('取消收藏'),
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
      case 'redo':
        unawaited(
          Navigator.of(context).pushNamed(
            AppRoutes.favoriteRedo,
            arguments: RedoArgs(
              favoriteIds: <String>[favorite.id],
              title: '第 ${favorite.label} 题',
            ),
          ),
        );
      case 'remove':
        await ref.read(favoriteStoreProvider).remove(favorite.id);
        ref.invalidate(favoritesProvider);
        await _load();
    }
  }
}
