import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/favorite/favorite_store.dart';
import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/ai/knowledge_tag.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/favorite_group.dart';
import 'package:shuaqi/domain/model/favorite_set_plan.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';
import 'package:shuaqi/state/ai_providers.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/favorite_providers.dart';
import 'package:shuaqi/ui/favorites/favorite_card.dart';
import 'package:shuaqi/ui/favorites/favorite_redo_page.dart';
import 'package:shuaqi/ui/favorites/favorite_set_page.dart';
import 'package:shuaqi/ui/favorites/favorite_tag_editor.dart';
import 'package:shuaqi/ui/favorites/favorite_workbook_page.dart';
import 'package:shuaqi/ui/favorites/question_view_page.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/settings/ai_settings_sheet.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/empty_state.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';

/// 收藏夹 tab（T8.2 → 058 重构）：**全部 / 按试卷 / 按知识点 / 组卷** 四种呈现。
///
/// - 全部：按更新时间倒序的题目卡片（默认）；
/// - 按试卷：一张卷一张「文件夹卡」，点开才看这一卷的收藏；长按改名/去书架/删本卷收藏；
/// - 按知识点：标签条（全部 / 各知识点 / 未归纳 / ＋ / AI 归纳）+ 分组卡片墙；
/// - 组卷：命名题集列表（可搜）。
///
/// 搜索是**统一**的：一边匹配题目，一边匹配组卷；组卷结果带「组卷」标记。
/// 多选只有两个动作：**组卷**（加入/新建）、**点亮知识点**（归入已有/新建）。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key, required this.onGoBookshelf});

  final VoidCallback onGoBookshelf;

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

enum _FavoritesView { all, byWorkbook, byKnowledge, sets }

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  _FavoritesView _view = _FavoritesView.all;
  String _query = '';
  String? _selectedTag;
  bool _selecting = false;
  final Set<String> _selectedIds = <String>{};
  bool _aiTagging = false;

  /// 上次任何"归纳行为"的时间；AI 归纳弹窗据此默认勾选"之后新增的未归纳题"。
  int _lastTagAt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTagClock());
  }

  Future<void> _loadTagClock() async {
    final int at = await ref.read(favoriteStoreProvider).loadLastTagAt();
    if (mounted) {
      setState(() => _lastTagAt = at);
    }
  }

  Future<void> _touchTagClock() async {
    await ref.read(favoriteStoreProvider).touchLastTagAt();
    if (mounted) {
      setState(() => _lastTagAt = DateTime.now().toUtc().millisecondsSinceEpoch);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Favorite>> async = ref.watch(favoritesProvider);
    final AsyncValue<List<FavoriteSet>> setsAsync = ref.watch(
      favoriteSetsProvider,
    );
    final bool showSelectionEntry =
        _view != _FavoritesView.sets || _query.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting ? '选择题目' : '收藏夹'),
        actions: <Widget>[
          if (!_selecting && showSelectionEntry)
            IconButton(
              tooltip: '选择题目',
              onPressed: () => setState(() => _selecting = true),
              icon: const Icon(Icons.checklist_outlined),
            ),
          if (_selecting)
            IconButton(
              tooltip: '退出选择',
              onPressed: () => setState(() {
                _selecting = false;
                _selectedIds.clear();
              }),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            if (_selecting)
              _SelectionHeader(
                count: _selectedIds.length,
                onSelectAll: () {
                  final List<Favorite> visible = _visibleQuestions(async);
                  setState(() {
                    _selectedIds
                      ..clear()
                      ..addAll(visible.map((Favorite f) => f.id));
                  });
                },
                onCancel: () => setState(() {
                  _selecting = false;
                  _selectedIds.clear();
                }),
              )
            else ...<Widget>[
              _SearchBar(
                onChanged: (String value) => setState(() => _query = value),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.lg,
                  ShqSpace.xs,
                  ShqSpace.lg,
                  ShqSpace.sm,
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<_FavoritesView>(
                    segments: const <ButtonSegment<_FavoritesView>>[
                      ButtonSegment<_FavoritesView>(
                        value: _FavoritesView.all,
                        label: Text('全部'),
                        icon: Icon(Icons.grid_view_outlined, size: 18),
                      ),
                      ButtonSegment<_FavoritesView>(
                        value: _FavoritesView.byWorkbook,
                        label: Text('按试卷'),
                        icon: Icon(Icons.auto_stories_outlined, size: 18),
                      ),
                      ButtonSegment<_FavoritesView>(
                        value: _FavoritesView.byKnowledge,
                        label: Text('按知识点'),
                        icon: Icon(Icons.sell_outlined, size: 18),
                      ),
                      ButtonSegment<_FavoritesView>(
                        value: _FavoritesView.sets,
                        label: Text('组卷'),
                        icon: Icon(Icons.playlist_play, size: 18),
                      ),
                    ],
                    selected: <_FavoritesView>{_view},
                    onSelectionChanged: (Set<_FavoritesView> selection) {
                      setState(() {
                        _view = selection.first;
                        if (_view != _FavoritesView.byKnowledge) {
                          _selectedTag = null;
                        }
                      });
                    },
                    showSelectedIcon: false,
                  ),
                ),
              ),
            ],
            Expanded(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => EmptyState(
                  icon: Icons.bookmarks_outlined,
                  title: '收藏夹加载失败',
                  message: '数据暂时读不出来，稍后再试。',
                  actionLabel: '去书架',
                  onAction: widget.onGoBookshelf,
                ),
                data: (List<Favorite> favorites) => _buildContent(
                  favorites,
                  setsAsync.maybeWhen(
                    data: (List<FavoriteSet> value) => value,
                    orElse: () => const <FavoriteSet>[],
                  ),
                ),
              ),
            ),
            if (_selecting)
              _SelectionBar(
                count: _selectedIds.length,
                onRemove: _selectedIds.isEmpty
                    ? null
                    : () => unawaited(_removeSelected()),
                onSet: _selectedIds.isEmpty
                    ? null
                    : () => unawaited(_openSetPickerForSelection()),
                onTag: _selectedIds.isEmpty
                    ? null
                    : () => unawaited(_openTagPickerForSelection()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
    List<Favorite> favorites,
    List<FavoriteSet> sets,
  ) {
    final bool searching = _query.trim().isNotEmpty;
    if (searching) {
      final List<Favorite> matchedQuestions = searchFavorites(
        favorites,
        _query,
      );
      final List<FavoriteSet> matchedSets = searchFavoriteSets(sets, _query);
      return _SearchResults(
        sets: matchedSets,
        favorites: matchedQuestions,
        selecting: _selecting,
        selectedIds: _selectedIds,
        onSet: _openSet,
        onTapFavorite: (Favorite favorite) {
          if (_selecting) {
            _toggleSelected(favorite.id);
          } else {
            _open(favorite);
          }
        },
        onLongPressFavorite: (Favorite favorite) {
          if (_selecting) {
            _toggleSelected(favorite.id);
          } else {
            unawaited(_openMenu(favorite));
          }
        },
      );
    }
    // 多选不再强制铺成"全部"：选择跟随当前视图（全部 / 按试卷的整卷 /
    // 按知识点的当前标签），「全选」也只选当前视图里的题。
    switch (_view) {
      case _FavoritesView.all:
        return _AllWall(
          favorites: favorites,
          selecting: _selecting,
          selectedIds: _selectedIds,
          onTap: (Favorite favorite) {
            if (_selecting) {
              _toggleSelected(favorite.id);
            } else {
              _open(favorite);
            }
          },
          onLongPress: (Favorite favorite) {
            if (_selecting) {
              _toggleSelected(favorite.id);
            } else {
              unawaited(_openMenu(favorite));
            }
          },
        );
      case _FavoritesView.byWorkbook:
        return _WorkbookWall(
          groups: groupByWorkbook(favorites),
          selecting: _selecting,
          selectedIds: _selectedIds,
          onOpen: (FavoriteGroup group) => _openWorkbook(group),
          onMenu: (FavoriteGroup group) => unawaited(_openWorkbookMenu(group)),
          onToggleGroup: (FavoriteGroup group) {
            final List<String> ids = <String>[
              for (final Favorite favorite in group.items) favorite.id,
            ];
            final bool allSelected = ids.every(_selectedIds.contains);
            setState(() {
              if (allSelected) {
                _selectedIds.removeAll(ids);
              } else {
                _selectedIds.addAll(ids);
              }
            });
          },
        );
      case _FavoritesView.byKnowledge:
        final List<Favorite> filtered = filterByTag(favorites, _selectedTag);
        final List<FavoriteGroup> groups = groupByKnowledge(filtered);
        return Column(
          children: <Widget>[
            _TagStrip(
              tags: distinctKnowledgeTags(favorites),
              hasUnfiled: hasUnfiled(favorites),
              selected: _selectedTag,
              aiBusy: _aiTagging,
              onSelected: (String? tag) =>
                  setState(() => _selectedTag = tag),
              onAddTag: () => unawaited(_addTag(favorites)),
              onAiTag: () => unawaited(_openAiTagDialog()),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? EmptyState(
                      icon: Icons.sell_outlined,
                      title: '这个知识点下还没有题',
                      message: '换个标签，或在「全部」里长按题目编辑知识点。',
                      actionLabel: '看全部',
                      onAction: () => setState(() => _selectedTag = null),
                    )
                  : _GroupedWall(
                      groups: groups,
                      selecting: _selecting,
                      selectedIds: _selectedIds,
                      onTap: (Favorite favorite) {
                        if (_selecting) {
                          _toggleSelected(favorite.id);
                        } else {
                          _open(favorite);
                        }
                      },
                      onLongPress: (Favorite favorite) {
                        if (_selecting) {
                          _toggleSelected(favorite.id);
                        } else {
                          unawaited(_openMenu(favorite));
                        }
                      },
                    ),
            ),
          ],
        );
      case _FavoritesView.sets:
        return _SetsView(
          sets: sets,
          onCreate: () => unawaited(_createEmptySet()),
          onOpen: _openSet,
          onPractice: _practiceSet,
          onMenu: (FavoriteSet set) => unawaited(_setMenu(set)),
        );
    }
  }

  /// 当前可见的题目（全选只选看得见的）。
  /// 「全选」只选当前视图可见的题：
  /// - 全部 / 按试卷：当前列表里的全部题目；
  /// - 按知识点：当前选中标签（或未归纳）下的题；
  /// - 搜索结果：命中的题目。
  List<Favorite> _visibleQuestions(AsyncValue<List<Favorite>> async) {
    final List<Favorite> all = async.maybeWhen(
      data: (List<Favorite> value) => value,
      orElse: () => const <Favorite>[],
    );
    final List<Favorite> searched = searchFavorites(all, _query);
    return _view == _FavoritesView.byKnowledge && _query.trim().isEmpty
        ? filterByTag(searched, _selectedTag)
        : searched;
  }

  Future<void> _removeSelected() async {
    final List<String> ids = _orderedSelected();
    if (ids.isEmpty) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('取消收藏 ${ids.length} 题？'),
        content: const Text('只删除这些题的收藏快照，原卷与作答不受影响。组卷里的成员也会一并移除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('再想想'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('取消收藏'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final FavoriteStore store = ref.read(favoriteStoreProvider);
    for (final String id in ids) {
      await store.remove(id);
    }
    ref.invalidate(favoritesProvider);
    ref.invalidate(favoriteSetsProvider);
    if (!mounted) {
      return;
    }
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
    _showTip('已取消 ${ids.length} 道题的收藏');
  }


  void _toggleSelected(String id) {
    setState(() {
      if (!_selectedIds.add(id)) {
        _selectedIds.remove(id);
      }
    });
  }

  void _open(Favorite favorite) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.favoriteQuestion,
        arguments: QuestionViewArgs(favoriteId: favorite.id),
      ),
    );
  }

  void _openSet(FavoriteSet set) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.favoriteSet,
        arguments: FavoriteSetArgs(setId: set.id),
      ),
    );
  }

  void _openWorkbook(FavoriteGroup group) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.favoriteWorkbook,
        arguments: FavoriteWorkbookArgs(
          workbookId: group.key,
          title: group.title,
        ),
      ),
    );
  }

  void _practiceSet(FavoriteSet set) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.favoriteRedo,
        arguments: RedoArgs(
          favoriteIds: const <String>[],
          title: set.displayName,
          setId: set.id,
        ),
      ),
    );
  }

  // ---- 长按菜单（单题） ----

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
              leading: const Icon(Icons.sell_outlined),
              title: const Text('编辑知识点'),
              onTap: () => Navigator.pop(context, 'tag'),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_outlined),
              title: const Text('组卷…'),
              onTap: () => Navigator.pop(context, 'set'),
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
      case 'tag':
        await _editKnowledge(favorite);
      case 'set':
        await _openSetPicker(<String>[favorite.id]);
      case 'remove':
        await ref.read(favoriteStoreProvider).remove(favorite.id);
        ref.invalidate(favoritesProvider);
        if (mounted) {
          _showTip('已取消收藏');
        }
    }
  }

  Future<void> _editKnowledge(Favorite favorite) async {
    final List<Favorite> all =
        ref.read(favoritesProvider).value ?? const <Favorite>[];
    final List<String>? tags = await showFavoriteTagEditor(
      context,
      initial: favorite.knowledgeTags,
      suggestions: distinctKnowledgeTags(all),
    );
    if (tags == null || !mounted) {
      return;
    }
    await ref
        .read(favoriteStoreProvider)
        .updateKnowledgeTags(favorite.id, tags);
    ref.invalidate(favoritesProvider);
    await _touchTagClock();
  }

  // ---- 按试卷：文件夹卡的长按菜单 ----

  Future<void> _openWorkbookMenu(FavoriteGroup group) async {
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
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名试卷'),
              subtitle: const Text('与书架双向同步（改名后书架也变）'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.auto_stories_outlined),
              title: const Text('在书架中查看'),
              subtitle: const Text('回到书架（源卷还在时）'),
              onTap: () => Navigator.pop(context, 'shelf'),
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_remove_outlined),
              title: const Text('删除本卷收藏'),
              subtitle: const Text('只删收藏快照，不删原卷'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    switch (action) {
      case 'rename':
        await _renameWorkbook(group);
      case 'shelf':
        widget.onGoBookshelf();
      case 'delete':
        await _deleteWorkbookFavorites(group);
    }
  }

  Future<void> _renameWorkbook(FavoriteGroup group) async {
    final TextEditingController controller = TextEditingController(
      text: group.title,
    );
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('重命名试卷'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '卷名'),
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
    // 书架 → 收藏：改 workbook 表 + 同步所有快照上的卷名。
    if (group.key.isNotEmpty) {
      try {
        await ref.read(workbookDaoProvider).rename(group.key, name);
      } on Object {
        // 卷已删（只剩快照）时改不到 workbook，但快照卷名仍要改。
      }
      await ref.read(favoriteStoreProvider).renameWorkbook(group.key, name);
    }
    ref.invalidate(bookshelfProvider);
    ref.invalidate(favoritesProvider);
    if (mounted) {
      _showTip('已重命名为「$name」');
    }
  }

  Future<void> _deleteWorkbookFavorites(FavoriteGroup group) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除本卷收藏'),
        content: Text(
          '将删除「${group.title}」的 ${group.items.length} 道收藏（含快照）。'
          '原卷与作答不受影响。',
        ),
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
    final int removed = await ref
        .read(favoriteStoreProvider)
        .removeOfWorkbook(group.key);
    ref.invalidate(favoritesProvider);
    ref.invalidate(favoriteSetsProvider);
    if (mounted) {
      _showTip('已删除 $removed 道收藏');
    }
  }

  // ---- 组卷 ----

  Future<void> _openSetPickerForSelection() async {
    final List<String> ids = _orderedSelected();
    if (ids.isEmpty) {
      return;
    }
    final bool changed = await _openSetPicker(ids);
    if (changed && mounted) {
      setState(() {
        _selecting = false;
        _selectedIds.clear();
      });
    }
  }

  /// 组卷选择（居中弹窗）：加入已有 / 新建。返回是否真的写入了组卷。
  Future<bool> _openSetPicker(List<String> favoriteIds) async {
    final FavoriteStore store = ref.read(favoriteStoreProvider);
    final List<FavoriteSet> sets = await store.listSets();
    if (!mounted) {
      return false;
    }
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('组卷 · ${favoriteIds.length} 题'),
        content: SizedBox(
          width: double.maxFinite,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final FavoriteSet set in sets)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.playlist_play),
                    title: Text(set.displayName),
                    subtitle: Text('${set.itemCount} 题'),
                    onTap: () => Navigator.pop(context, set.id),
                  ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.add),
                  title: const Text('新建组卷…'),
                  onTap: () => Navigator.pop(context, '__new__'),
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) {
      return false;
    }
    if (picked == '__new__') {
      final String? name = await _promptSetName(
        title: '新建组卷',
        hint: '如：三角函数易错 10 题',
        confirmLabel: '创建（${favoriteIds.length} 题）',
      );
      if (name == null || !mounted) {
        return false;
      }
      final FavoriteSet set = await store.createSet(
        name: name,
        favoriteIds: favoriteIds,
      );
      ref.invalidate(favoriteSetsProvider);
      if (mounted) {
        _showTip('已新建「${set.displayName}」· ${set.itemCount} 题');
      }
      return true;
    }
    final FavoriteSet target = sets.firstWhere(
      (FavoriteSet s) => s.id == picked,
      orElse: () => sets.first,
    );
    final int added = await store.addToSet(picked, favoriteIds);
    ref.invalidate(favoriteSetsProvider);
    if (mounted) {
      _showTip(
        added == 0
            ? '这些题已经在「${target.displayName}」里了'
            : '已加入「${target.displayName}」· 新增 $added 题',
      );
    }
    return added > 0;
  }

  Future<void> _createEmptySet() async {
    final String? name = await _promptSetName(
      title: '新建题集',
      hint: '如：周末错题回炉',
      confirmLabel: '创建',
    );
    if (name == null || !mounted) {
      return;
    }
    final FavoriteSet set = await ref
        .read(favoriteStoreProvider)
        .createSet(name: name);
    ref.invalidate(favoriteSetsProvider);
    if (!mounted) {
      return;
    }
    _showTip('已新建「${set.displayName}」，去加题吧');
    _openSet(set);
  }

  Future<void> _setMenu(FavoriteSet set) async {
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
              leading: const Icon(Icons.play_arrow),
              title: const Text('开始连刷'),
              onTap: () => Navigator.pop(context, 'play'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除题集'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    switch (action) {
      case 'play':
        _practiceSet(set);
      case 'rename':
        final String? name = await _promptSetName(
          title: '重命名题集',
          hint: '题集名',
          confirmLabel: '保存',
          initial: set.displayName,
        );
        if (name == null || !mounted) {
          return;
        }
        await ref.read(favoriteStoreProvider).renameSet(set.id, name);
        ref.invalidate(favoriteSetsProvider);
      case 'delete':
        final bool? confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('删除题集'),
            content: Text('「${set.displayName}」会被删除。题目仍留在收藏夹，不影响收藏。'),
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
          _showTip('已删除「${set.displayName}」');
        }
    }
  }

  Future<String?> _promptSetName({
    required String title,
    required String hint,
    required String confirmLabel,
    String initial = '',
  }) async {
    final TextEditingController controller = TextEditingController(
      text: initial,
    );
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
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
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    return name;
  }

  // ---- 知识点 ----

  Future<void> _openTagPickerForSelection() async {
    final List<String> ids = _orderedSelected();
    if (ids.isEmpty) {
      return;
    }
    final bool changed = await _openTagPicker(ids);
    if (changed && mounted) {
      setState(() {
        _selecting = false;
        _selectedIds.clear();
      });
    }
  }

  /// 点亮知识点（居中弹窗）：多选已有标签 + 新建。返回是否真的写了标签。
  Future<bool> _openTagPicker(List<String> favoriteIds) async {
    final List<Favorite> all =
        ref.read(favoritesProvider).value ?? const <Favorite>[];
    final List<String> existing = distinctKnowledgeTags(all);
    final List<String> extra = <String>[];
    final Set<String> selected = <String>{};
    bool aiRequested = false;
    final bool? applied = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => AlertDialog(
          title: Text('点亮知识点 · ${favoriteIds.length} 题'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (existing.isEmpty && extra.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: ShqSpace.sm),
                      child: Text(
                        '还没有知识点，先新建一个。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  Wrap(
                    spacing: ShqSpace.sm,
                    runSpacing: ShqSpace.sm,
                    children: <Widget>[
                      for (final String tag in <String>[
                        ...existing,
                        ...extra,
                      ])
                        FilterChip(
                          label: Text(tag),
                          selected: selected.contains(tag),
                          onSelected: (bool value) => setState(() {
                            if (value) {
                              selected.add(tag);
                            } else {
                              selected.remove(tag);
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: ShqSpace.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final String? name = await _promptTagName();
                        if (name == null || name.isEmpty) {
                          return;
                        }
                        if (!extra.contains(name) && !existing.contains(name)) {
                          extra.add(name);
                        }
                        selected.add(name);
                        setState(() {});
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新建知识点…'),
                    ),
                  ),
                  const Divider(height: 1),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () {
                        aiRequested = true;
                        Navigator.pop(context, false);
                      },
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('AI 归纳这些题…'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text('点亮 ${selected.length} 个知识点'),
            ),
          ],
        ),
      ),
    );
    if (aiRequested) {
      await _runAiTag(favoriteIds);
      return true;
    }
    if (applied != true || !mounted || selected.isEmpty) {
      return false;
    }
    final FavoriteStore store = ref.read(favoriteStoreProvider);
    for (final String tag in selected) {
      await store.appendKnowledgeTag(favoriteIds, tag);
    }
    ref.invalidate(favoritesProvider);
    await _touchTagClock();
    if (mounted) {
      _showTip('已为 ${favoriteIds.length} 题点亮 ${selected.length} 个知识点');
    }
    return true;
  }

  /// 「AI 归纳」：先给确认清单（默认只勾选上次归纳后新增、仍未归纳的题）。
  Future<void> _openAiTagDialog() async {
    if (_aiTagging) {
      return;
    }
    final List<Favorite> all =
        ref.read(favoritesProvider).value ?? const <Favorite>[];
    final List<Favorite> unfiled = <Favorite>[
      for (final Favorite favorite in all)
        if (favorite.knowledgeTags.isEmpty) favorite,
    ];
    if (unfiled.isEmpty) {
      _showTip('没有待归纳的题');
      return;
    }
    final Set<String> selected = <String>{
      for (final Favorite favorite in unfiled)
        if (isNewSinceTag(favorite.createdAt, _lastTagAt)) favorite.id,
    };
    final List<String>? picked = await showDialog<List<String>>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          final int newCount = unfiled
              .where((Favorite f) => isNewSinceTag(f.createdAt, _lastTagAt))
              .length;
          return AlertDialog(
            title: const Text('AI 归纳知识点'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _lastTagAt == 0
                        ? '共 ${unfiled.length} 道未归纳，默认全选；可自行增减。'
                        : '共 ${unfiled.length} 道未归纳，其中上次归纳后新增 $newCount 道（默认勾选）。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: ShqSpace.xs),
                  Row(
                    children: <Widget>[
                      TextButton(
                        onPressed: () => setState(() {
                          selected
                            ..clear()
                            ..addAll(unfiled.map((Favorite f) => f.id));
                        }),
                        child: const Text('全选'),
                      ),
                      TextButton(
                        onPressed: () => setState(selected.clear),
                        child: const Text('清空'),
                      ),
                      const Spacer(),
                      Text('已选 ${selected.length} 题'),
                    ],
                  ),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 360),
                      child: ListView(
                        shrinkWrap: true,
                        children: <Widget>[
                          for (final Favorite favorite in unfiled)
                            CheckboxListTile(
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              value: selected.contains(favorite.id),
                              title: Text('第 ${favorite.label} 题'),
                              subtitle: Text(
                                '${favorite.workbookTitle}'
                                '${isNewSinceTag(favorite.createdAt, _lastTagAt) && _lastTagAt > 0 ? ' · 新增' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onChanged: (bool? value) => setState(() {
                                if (value == true) {
                                  selected.add(favorite.id);
                                } else {
                                  selected.remove(favorite.id);
                                }
                              }),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
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
                    : () => Navigator.pop(
                        context,
                        selected.toList(growable: false),
                      ),
                child: Text('归纳 ${selected.length} 题'),
              ),
            ],
          );
        },
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) {
      return;
    }
    await _runAiTag(picked);
  }

  Future<void> _runAiTag(List<String> favoriteIds) async {
    final List<Favorite> all =
        ref.read(favoritesProvider).value ?? const <Favorite>[];
    final List<Favorite> targets = <Favorite>[
      for (final Favorite favorite in all)
        if (favoriteIds.contains(favorite.id) &&
            favorite.knowledgeTags.isEmpty)
          favorite,
    ];
    if (targets.isEmpty) {
      _showTip('选中的题已经有知识点，无需归纳');
      return;
    }
    final LlmConfig config = await ref.read(aiConfigProvider.future);
    if (!mounted) {
      return;
    }
    if (!config.isConfigured) {
      final bool saved = await showAiSettingsSheet(context, initial: config);
      if (saved) {
        ref.invalidate(aiConfigProvider);
      }
      return;
    }
    setState(() => _aiTagging = true);
    try {
      final Map<String, List<String>> tags = await ref
          .read(aiServiceProvider('favorites'))
          .tagKnowledge(
            config: config,
            items: <KnowledgeTagItem>[
              for (final Favorite favorite in targets)
                KnowledgeTagItem(
                  id: favorite.id,
                  label: favorite.label,
                  workbookTitle: favorite.workbookTitle,
                  kind: favorite.kind,
                  stemText: favorite.stemText,
                ),
            ],
          );
      final FavoriteStore store = ref.read(favoriteStoreProvider);
      final Map<String, List<String>> reviewed = await _reviewAiTags(
        tags,
        targets,
      );
      if (!mounted) {
        return;
      }
      if (reviewed.isEmpty) {
        _showTip('已取消，未写入任何知识点');
        return;
      }
      int applied = 0;
      for (final MapEntry<String, List<String>> entry in reviewed.entries) {
        if (entry.value.isEmpty) {
          continue;
        }
        await store.updateKnowledgeTags(entry.key, entry.value);
        applied++;
      }
      ref.invalidate(favoritesProvider);
      if (applied > 0) {
        await _touchTagClock();
      }
      if (mounted) {
        _showTip(
          applied == 0
              ? 'AI 没有给出可用的标签，题目保持未归纳'
              : '已为 $applied 道题归纳知识点',
        );
      }
    } on AiFailure catch (error) {
      if (mounted) {
        _showTip(error.message);
      }
    } on Object catch (error) {
      if (mounted) {
        _showTip('AI 归纳失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _aiTagging = false);
      }
    }
  }

  /// AI 归纳结果确认（T8.5 / 059 第 3 条）：逐题可增减标签、可整题不采用。
  ///
  /// 返回"确认后要写库的 id → 标签"；null/空 = 取消。
  Future<Map<String, List<String>>> _reviewAiTags(
    Map<String, List<String>> tags,
    List<Favorite> targets,
  ) async {
    final Map<String, Favorite> byId = <String, Favorite>{
      for (final Favorite favorite in targets) favorite.id: favorite,
    };
    final Map<String, List<String>> edited = <String, List<String>>{
      for (final MapEntry<String, List<String>> entry in tags.entries)
        if (byId.containsKey(entry.key)) entry.key: List<String>.of(entry.value),
    };
    if (edited.isEmpty) {
      return <String, List<String>>{};
    }
    final Set<String> included = <String>{...edited.keys};
    final Map<String, List<String>>? confirmed =
        await showDialog<Map<String, List<String>>>(
          context: context,
          builder: (BuildContext context) => StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              Future<void> removeTag(String id, String tag) async {
                setState(() {
                  edited[id]?.remove(tag);
                });
              }

              Future<void> addTag(String id) async {
                final String? name = await _promptTagName();
                if (name == null || name.isEmpty) {
                  return;
                }
                setState(() {
                  final List<String> list =
                      edited[id] ?? <String>[];
                  if (!list.contains(name) && list.length < 5) {
                    list.add(name);
                  }
                  edited[id] = list;
                });
              }

              return AlertDialog(
                title: const Text('AI 归纳结果'),
                content: SizedBox(
                  width: double.maxFinite,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '共 ${edited.length} 道题。可以删改标签，或取消勾选整题不采用。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: ShqSpace.xs),
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 420),
                          child: ListView(
                            shrinkWrap: true,
                            children: <Widget>[
                              for (final MapEntry<String, List<String>>
                                  entry in edited.entries)
                                if (byId[entry.key] != null)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: ShqSpace.sm,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Checkbox(
                                          value: included.contains(entry.key),
                                          onChanged: (bool? value) =>
                                              setState(() {
                                                if (value == true) {
                                                  included.add(entry.key);
                                                } else {
                                                  included.remove(entry.key);
                                                }
                                              }),
                                        ),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: <Widget>[
                                              Text(
                                                '第 ${byId[entry.key]!.label} 题 · '
                                                '${byId[entry.key]!.workbookTitle}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.labelSmall,
                                              ),
                                              Wrap(
                                                spacing: ShqSpace.xs,
                                                runSpacing: 2,
                                                crossAxisAlignment:
                                                    WrapCrossAlignment.center,
                                                children: <Widget>[
                                                  for (final String tag
                                                      in entry.value)
                                                    InputChip(
                                                      label: Text(tag),
                                                      onDeleted: () =>
                                                          removeTag(
                                                            entry.key,
                                                            tag,
                                                          ),
                                                      visualDensity:
                                                          VisualDensity.compact,
                                                    ),
                                                  ActionChip(
                                                    avatar: const Icon(
                                                      Icons.add,
                                                      size: 14,
                                                    ),
                                                    label: const Text('标签'),
                                                    onPressed: () =>
                                                        addTag(entry.key),
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: included.isEmpty
                        ? null
                        : () => Navigator.pop(context, <String, List<String>>{
                            for (final String id in included)
                              if (edited[id] != null && edited[id]!.isNotEmpty)
                                id: edited[id]!,
                          }),
                    child: Text('写入 ${included.length} 题'),
                  ),
                ],
              );
            },
          ),
        );
    return confirmed ?? <String, List<String>>{};
  }

  /// 标签条「＋」：新建一个知识点标签，并把选中的收藏归入它。
  Future<void> _addTag(List<Favorite> all) async {
    final String? name = await _promptTagName();
    if (name == null || name.isEmpty || !mounted) {
      return;
    }
    final List<String>? picked = await _pickForTag(all, name);
    if (picked == null || picked.isEmpty || !mounted) {
      return;
    }
    await ref.read(favoriteStoreProvider).appendKnowledgeTag(picked, name);
    ref.invalidate(favoritesProvider);
    await _touchTagClock();
    if (mounted) {
      _showTip('已把 ${picked.length} 道题归入「$name」');
    }
  }

  Future<String?> _promptTagName() async {
    final TextEditingController controller = TextEditingController();
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('新建知识点标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '如：三角函数'),
          onSubmitted: (String value) {
            final String trimmed = value.trim();
            if (trimmed.isNotEmpty) {
              Navigator.pop(context, trimmed);
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
              final String trimmed = controller.text.trim();
              if (trimmed.isNotEmpty) {
                Navigator.pop(context, trimmed);
              }
            },
            child: const Text('下一步'),
          ),
        ],
      ),
    );
    controller.dispose();
    return name;
  }

  List<String> _orderedSelected() {
    final List<Favorite> all = _visibleQuestions(ref.read(favoritesProvider));
    final List<String> out = <String>[
      for (final Favorite favorite in all)
        if (_selectedIds.contains(favorite.id)) favorite.id,
    ];
    for (final String id in _selectedIds) {
      if (!out.contains(id)) {
        out.add(id);
      }
    }
    return out;
  }

  /// 选要归入新标签的题；默认勾选「未归纳」的题。
  Future<List<String>?> _pickForTag(List<Favorite> all, String tag) async {
    final Set<String> selected = <String>{
      for (final Favorite favorite in all)
        if (favorite.knowledgeTags.isEmpty) favorite.id,
    };
    final List<String>? result = await showDialog<List<String>>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => AlertDialog(
          title: Text('归入「$tag」'),
          content: SizedBox(
            width: double.maxFinite,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final Favorite favorite in all)
                    CheckboxListTile(
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text('第 ${favorite.label} 题'),
                      subtitle: Text(favorite.workbookTitle),
                      value: selected.contains(favorite.id),
                      onChanged: (bool? value) => setState(() {
                        if (value == true) {
                          selected.add(favorite.id);
                        } else {
                          selected.remove(favorite.id);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, selected.toList(growable: false)),
              child: Text('归入 ${selected.length} 题'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  void _showTip(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 2200),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

/// 多选时的顶部条：已选数量 / 全选 / 取消。
class _SelectionHeader extends StatelessWidget {
  const _SelectionHeader({
    required this.count,
    required this.onSelectAll,
    required this.onCancel,
  });

  final int count;
  final VoidCallback onSelectAll;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.sm,
        ShqSpace.sm,
        ShqSpace.xs,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.checklist, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: ShqSpace.sm),
          Text(
            count == 0 ? '点卡片 / 文件夹选择题目' : '已选 $count 题',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          TextButton(onPressed: onSelectAll, child: const Text('全选')),
          TextButton(onPressed: onCancel, child: const Text('取消')),
        ],
      ),
    );
  }
}

/// 多选底部：取消收藏 / 点亮知识点 / 组卷。
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onRemove,
    required this.onSet,
    required this.onTag,
  });

  final int count;
  final VoidCallback? onRemove;
  final VoidCallback? onSet;
  final VoidCallback? onTag;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.sm,
        ShqSpace.lg,
        ShqSpace.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              count == 0 ? '选择要处理的题' : '共 $count 题',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onRemove,
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
            label: const Text('取消收藏'),
          ),
          const SizedBox(width: ShqSpace.xs),
          FilledButton.tonalIcon(
            onPressed: onTag,
            icon: const Icon(Icons.lightbulb_outline, size: 18),
            label: const Text('点亮知识点'),
          ),
          const SizedBox(width: ShqSpace.sm),
          FilledButton.icon(
            onPressed: onSet,
            icon: const Icon(Icons.playlist_add, size: 18),
            label: const Text('组卷'),
          ),
        ],
      ),
    );
  }
}

/// 搜索框。
class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.sm,
        ShqSpace.lg,
        ShqSpace.xs,
      ),
      child: TextField(
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: '搜索题目、试卷、知识点或组卷',
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          filled: true,
          fillColor: scheme.surfaceContainerHigh,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ShqRadius.pill),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: ShqSpace.md,
            vertical: ShqSpace.sm,
          ),
        ),
      ),
    );
  }
}

/// 「全部」：按更新时间倒序的题目卡片。
class _AllWall extends StatelessWidget {
  const _AllWall({
    required this.favorites,
    required this.selecting,
    required this.selectedIds,
    required this.onTap,
    required this.onLongPress,
  });

  final List<Favorite> favorites;
  final bool selecting;
  final Set<String> selectedIds;
  final void Function(Favorite favorite) onTap;
  final void Function(Favorite favorite) onLongPress;

  @override
  Widget build(BuildContext context) {
    if (favorites.isEmpty) {
      return const EmptyState(
        icon: Icons.bookmarks_outlined,
        title: '还没有收藏的题目',
        message: '在阅读器里选中题目点「收藏」，或批量选中后「收藏」，就会收进这里。',
      );
    }
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: _SectionHeader(title: '全部', count: favorites.length),
        ),
        _FavoritesGrid(
          items: favorites,
          selecting: selecting,
          selectedIds: selectedIds,
          onTap: onTap,
          onLongPress: onLongPress,
        ),
        const SliverToBoxAdapter(child: SizedBox(height: ShqSpace.xxl)),
      ],
    );
  }
}

/// 题目卡片网格（全部 / 搜索 / 知识点共用）。
class _FavoritesGrid extends StatelessWidget {
  const _FavoritesGrid({
    required this.items,
    required this.selecting,
    required this.selectedIds,
    required this.onTap,
    required this.onLongPress,
  });

  final List<Favorite> items;
  final bool selecting;
  final Set<String> selectedIds;
  final void Function(Favorite favorite) onTap;
  final void Function(Favorite favorite) onLongPress;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.md,
        0,
        ShqSpace.md,
        ShqSpace.md,
      ),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisSpacing: ShqSpace.sm,
          crossAxisSpacing: ShqSpace.sm,
          childAspectRatio: 0.92,
        ),
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            final Favorite favorite = items[index];
            return FavoriteCard(
              favorite: favorite,
              selected: selecting ? selectedIds.contains(favorite.id) : null,
              onTap: () => onTap(favorite),
              onLongPress: () => onLongPress(favorite),
            );
          },
          childCount: items.length,
        ),
      ),
    );
  }
}

/// 分组卡片墙（按知识点）。
class _GroupedWall extends StatelessWidget {
  const _GroupedWall({
    required this.groups,
    required this.selecting,
    required this.selectedIds,
    required this.onTap,
    required this.onLongPress,
  });

  final List<FavoriteGroup> groups;
  final bool selecting;
  final Set<String> selectedIds;
  final void Function(Favorite favorite) onTap;
  final void Function(Favorite favorite) onLongPress;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: <Widget>[
        for (final FavoriteGroup group in groups) ...<Widget>[
          SliverToBoxAdapter(child: _GroupHeader(group: group)),
          _FavoritesGrid(
            items: group.items,
            selecting: selecting,
            selectedIds: selectedIds,
            onTap: onTap,
            onLongPress: onLongPress,
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: ShqSpace.xxl)),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.count,
    this.unit = '题',
  });

  final String title;
  final int count;

  /// 计数单位：题目用"题"，按试卷的文件夹用"卷"。
  final String unit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.md,
        ShqSpace.lg,
        ShqSpace.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            '$count $unit',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group});

  final FavoriteGroup group;

  @override
  Widget build(BuildContext context) {
    return _SectionHeader(title: group.title, count: group.items.length);
  }
}

/// 「按试卷」：一张卷一张文件夹卡。
class _WorkbookWall extends StatelessWidget {
  const _WorkbookWall({
    required this.groups,
    required this.selecting,
    required this.selectedIds,
    required this.onOpen,
    required this.onMenu,
    required this.onToggleGroup,
  });

  final List<FavoriteGroup> groups;
  final bool selecting;
  final Set<String> selectedIds;
  final void Function(FavoriteGroup group) onOpen;
  final void Function(FavoriteGroup group) onMenu;
  final void Function(FavoriteGroup group) onToggleGroup;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return const EmptyState(
        icon: Icons.folder_open_outlined,
        title: '还没有收藏的试卷',
        message: '收藏题目后，这里会按试卷出现文件夹卡片。',
      );
    }
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: _SectionHeader(
            title: '按试卷',
            count: groups.length,
            unit: '卷',
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.md,
            0,
            ShqSpace.md,
            ShqSpace.xxl,
          ),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 380,
              mainAxisSpacing: ShqSpace.sm,
              crossAxisSpacing: ShqSpace.sm,
              childAspectRatio: 1.62,
            ),
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) {
                final FavoriteGroup group = groups[index];
                return _WorkbookFolderCard(
                  group: group,
                  now: now,
                  selecting: selecting,
                  selectedCount: group.items
                      .where((Favorite favorite) => selectedIds.contains(favorite.id))
                      .length,
                  onTap: () => selecting ? onToggleGroup(group) : onOpen(group),
                  onLongPress: () => selecting
                      ? onToggleGroup(group)
                      : onMenu(group),
                );
              },
              childCount: groups.length,
            ),
          ),
        ),
      ],
    );
  }
}

/// 文件夹样式的试卷卡：卷名 + 题数 + 最近更新 + 三张题面预览。
class _WorkbookFolderCard extends ConsumerWidget {
  const _WorkbookFolderCard({
    required this.group,
    required this.now,
    required this.selecting,
    required this.selectedCount,
    required this.onTap,
    required this.onLongPress,
  });

  final FavoriteGroup group;
  final int now;
  final bool selecting;

  /// 这一卷里已选中的题数（多选时点文件夹 = 整卷选中/取消）。
  final int selectedCount;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  bool get _allSelected =>
      group.items.isNotEmpty && selectedCount == group.items.length;

  bool get _partiallySelected => selectedCount > 0 && !_allSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool deleted = group.items.isNotEmpty && group.items.first.sourceDeleted;
    final int latest = group.items.isEmpty ? 0 : group.items.first.updatedAt;
    final Vault vault = ref.watch(vaultProvider);
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: 0.985,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShqRadius.md),
          side: selecting && _allSelected
              ? BorderSide(color: scheme.primary, width: 2)
              : BorderSide.none,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 文件夹"标签"：一眼看出这是卷，不是题。
            Container(
              padding: const EdgeInsets.fromLTRB(
                ShqSpace.md,
                ShqSpace.sm,
                ShqSpace.sm,
                ShqSpace.sm,
              ),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.55),
                borderRadius: const BorderRadius.only(
                  bottomRight: Radius.circular(ShqRadius.lg),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.folder_open,
                    size: 18,
                    color: scheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: ShqSpace.xs),
                  Expanded(
                    child: Text(
                      group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  if (selecting)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(
                        _allSelected
                            ? Icons.check_circle
                            : _partiallySelected
                            ? Icons.remove_circle_outline
                            : Icons.radio_button_unchecked,
                        size: 17,
                        color: _allSelected || _partiallySelected
                            ? scheme.primary
                            : scheme.onPrimaryContainer.withValues(alpha: 0.5),
                      ),
                    ),
                  Text(
                    selecting && selectedCount > 0
                        ? '$selectedCount/${group.items.length}'
                        : '${group.items.length} 题',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.sm,
                  ShqSpace.xs,
                  ShqSpace.sm,
                  ShqSpace.xs,
                ),
                child: Row(
                  children: <Widget>[
                    for (final Favorite favorite in group.items.take(3))
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(ShqRadius.sm),
                            child: ColoredBox(
                              color: ShqPaper.base,
                              child: Image.file(
                                vault.file(
                                  VaultPaths.favoriteStem(favorite.id),
                                ),
                                fit: BoxFit.contain,
                                errorBuilder:
                                    (
                                      BuildContext context,
                                      Object error,
                                      StackTrace? stackTrace,
                                    ) => Center(
                                      child: Text(
                                        '第 ${favorite.label} 题',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ShqSpace.md,
                0,
                ShqSpace.md,
                ShqSpace.sm,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      latest == 0
                          ? '打开看这一卷的收藏'
                          : '${relativeDay(latest, now)}更新',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ),
                  if (deleted)
                    Text(
                      '原卷已删',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    )
                  else
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: scheme.outline,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 统一搜索结果：匹配的组卷 + 匹配的题目。
class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.sets,
    required this.favorites,
    required this.selecting,
    required this.selectedIds,
    required this.onSet,
    required this.onTapFavorite,
    required this.onLongPressFavorite,
  });

  final List<FavoriteSet> sets;
  final List<Favorite> favorites;
  final bool selecting;
  final Set<String> selectedIds;
  final void Function(FavoriteSet set) onSet;
  final void Function(Favorite favorite) onTapFavorite;
  final void Function(Favorite favorite) onLongPressFavorite;

  @override
  Widget build(BuildContext context) {
    if (sets.isEmpty && favorites.isEmpty) {
      return const EmptyState(
        icon: Icons.search_off_outlined,
        title: '没有匹配的收藏',
        message: '换个关键词或标签试试。',
      );
    }
    return CustomScrollView(
      slivers: <Widget>[
        if (sets.isNotEmpty) ...<Widget>[
          SliverToBoxAdapter(
            child: _SectionHeader(
              title: '组卷',
              count: sets.length,
              unit: '个',
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) => _SetResultTile(
                set: sets[index],
                onTap: () => onSet(sets[index]),
              ),
              childCount: sets.length,
            ),
          ),
        ],
        if (favorites.isNotEmpty) ...<Widget>[
          SliverToBoxAdapter(
            child: _SectionHeader(title: '题目', count: favorites.length),
          ),
          _FavoritesGrid(
            items: favorites,
            selecting: selecting,
            selectedIds: selectedIds,
            onTap: onTapFavorite,
            onLongPress: onLongPressFavorite,
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: ShqSpace.xxl)),
      ],
    );
  }
}

/// 搜索结果里的组卷行：带「组卷」标记。
class _SetResultTile extends StatelessWidget {
  const _SetResultTile({required this.set, required this.onTap});

  final FavoriteSet set;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        0,
        ShqSpace.lg,
        ShqSpace.sm,
      ),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(ShqSpace.sm),
            child: Row(
              children: <Widget>[
                Icon(Icons.playlist_play, color: scheme.primary),
                const SizedBox(width: ShqSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              set.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: ShqSpace.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(
                                ShqRadius.pill,
                              ),
                            ),
                            child: Text(
                              '组卷',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onPrimaryContainer,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '${set.itemCount} 题 · 点开连刷',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 组卷视图：命名题集列表 + 新建入口。
class _SetsView extends StatelessWidget {
  const _SetsView({
    required this.sets,
    required this.onCreate,
    required this.onOpen,
    required this.onPractice,
    required this.onMenu,
  });

  final List<FavoriteSet> sets;
  final VoidCallback onCreate;
  final void Function(FavoriteSet set) onOpen;
  final void Function(FavoriteSet set) onPractice;
  final void Function(FavoriteSet set) onMenu;

  @override
  Widget build(BuildContext context) {
    if (sets.isEmpty) {
      return EmptyState(
        icon: Icons.playlist_add_outlined,
        title: '还没有组卷',
        message: '把收藏的题排成一份连刷题集：多选题目后点「组卷」，'
            '或长按任意题目「组卷…」。',
        actionLabel: '新建题集',
        onAction: onCreate,
      );
    }
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.sm,
        ShqSpace.lg,
        ShqSpace.xxl,
      ),
      children: <Widget>[
        for (final FavoriteSet set in sets) ...<Widget>[
          _SetCard(
            set: set,
            now: now,
            onTap: () => onOpen(set),
            onPractice: () => onPractice(set),
            onMenu: () => onMenu(set),
          ),
          const SizedBox(height: ShqSpace.sm),
        ],
        const SizedBox(height: ShqSpace.sm),
        OutlinedButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: const Text('新建空题集'),
        ),
      ],
    );
  }
}

class _SetCard extends StatelessWidget {
  const _SetCard({
    required this.set,
    required this.now,
    required this.onTap,
    required this.onPractice,
    required this.onMenu,
  });

  final FavoriteSet set;
  final int now;
  final VoidCallback onTap;
  final VoidCallback onPractice;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool empty = set.itemCount == 0;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(ShqRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.md,
            ShqSpace.sm,
            ShqSpace.sm,
            ShqSpace.sm,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: empty
                      ? scheme.surfaceContainerHighest
                      : scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(ShqRadius.sm),
                ),
                child: Icon(
                  Icons.playlist_play,
                  size: 22,
                  color: empty ? scheme.outline : scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: ShqSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      set.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      setSubtitle(
                        itemCount: set.itemCount,
                        updatedAtMs: set.updatedAt,
                        nowMs: now,
                      ),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: empty ? '先加题再刷' : '开始连刷',
                onPressed: empty ? null : onPractice,
                icon: const Icon(Icons.play_circle_outline),
              ),
              IconButton(
                tooltip: '更多',
                onPressed: onMenu,
                icon: const Icon(Icons.more_horiz),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「按知识点」顶部的横滑标签条：全部 + 各知识点 + 未归纳 + ＋ + AI 归纳。
class _TagStrip extends StatelessWidget {
  const _TagStrip({
    required this.tags,
    required this.hasUnfiled,
    required this.selected,
    required this.aiBusy,
    required this.onSelected,
    required this.onAddTag,
    required this.onAiTag,
  });

  final List<String> tags;
  final bool hasUnfiled;
  final String? selected;
  final bool aiBusy;
  final ValueChanged<String?> onSelected;
  final VoidCallback onAddTag;
  final VoidCallback onAiTag;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: ShqSpace.lg),
        children: <Widget>[
          _TagChip(
            label: '全部',
            selected: selected == null,
            onTap: () => onSelected(null),
          ),
          for (final String tag in tags)
            _TagChip(
              label: tag,
              selected: selected == tag,
              onTap: () => onSelected(tag),
            ),
          if (hasUnfiled)
            _TagChip(
              label: kUnfiledGroupTitle,
              selected: selected == kUnfiledGroupKey,
              onTap: () => onSelected(kUnfiledGroupKey),
            ),
          _AddTagChip(onTap: onAddTag),
          if (hasUnfiled) _AiTagChip(busy: aiBusy, onTap: onAiTag),
        ],
      ),
    );
  }
}

/// 标签条末尾的「AI 归纳」：打开确认清单后再归纳（T8.5 / 058）。
class _AiTagChip extends StatelessWidget {
  const _AiTagChip({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: ShqSpace.sm),
      child: Center(
        child: Pressable(
          onTap: busy ? null : onTap,
          scale: 0.94,
          haptic: true,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: ShqSpace.sm,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(ShqRadius.pill),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (busy)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onPrimaryContainer,
                    ),
                  )
                else
                  Icon(
                    Icons.auto_awesome,
                    size: 15,
                    color: scheme.onPrimaryContainer,
                  ),
                const SizedBox(width: 4),
                Text(
                  busy ? '归纳中…' : 'AI 归纳',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 标签条末尾的「＋」：新建知识点并批量归类。
class _AddTagChip extends StatelessWidget {
  const _AddTagChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: ShqSpace.sm),
      child: Center(
        child: Pressable(
          onTap: onTap,
          scale: 0.94,
          haptic: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShqRadius.pill),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Icon(
              Icons.add,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: ShqSpace.sm),
      child: Center(
        child: Pressable(
          onTap: onTap,
          scale: 0.94,
          haptic: true,
          child: AnimatedContainer(
            duration: ShqMotion.base,
            curve: ShqMotion.curveEmphasized,
            padding: const EdgeInsets.symmetric(
              horizontal: ShqSpace.md,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.secondaryContainer
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShqRadius.pill),
              border: Border.all(
                color: selected
                    ? scheme.secondaryContainer
                    : scheme.outlineVariant,
              ),
            ),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
