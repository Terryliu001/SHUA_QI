import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/shelf_folder.dart';
import 'package:shuaqi/domain/model/tag_color.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/ui/bookshelf/tag_bookmark.dart';
import 'package:shuaqi/ui/theme/hex_color.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 书架卡片的**长按菜单**（T1.4 收尾）。
///
/// 设计取向（iOS 优雅简练）：底部浮层 + 拖拽把手 + 发丝线分隔；
/// 删除用危险色但不用满屏红——它是确认流程，不是状态展示。
///
/// 「导出」刻意置灰：导出在 T7 才做。**能点但没反应是假功能**，
/// 置灰 + 一句"规划在 T7"才是诚实的交互。
Future<void> showWorkbookMenu(
  BuildContext context, {
  required Workbook workbook,
  required VoidCallback onRename,
  required VoidCallback onEditTags,
  required VoidCallback onMoveToFolder,
  required VoidCallback onDelete,
  required VoidCallback onExport,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) => _WorkbookMenuSheet(
      workbook: workbook,
      onRename: onRename,
      onEditTags: onEditTags,
      onMoveToFolder: onMoveToFolder,
      onDelete: onDelete,
      onExport: onExport,
    ),
  );
}

class _WorkbookMenuSheet extends StatelessWidget {
  const _WorkbookMenuSheet({
    required this.workbook,
    required this.onRename,
    required this.onEditTags,
    required this.onMoveToFolder,
    required this.onDelete,
    required this.onExport,
  });

  final Workbook workbook;
  final VoidCallback onRename;

  /// 「编辑标签」里已经带书签配色，不再单列一项（2026-10-24 用户口径）。
  final VoidCallback onEditTags;

  final VoidCallback onMoveToFolder;
  final VoidCallback onDelete;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    void closeAndRun(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(ShqRadius.xl),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(
          ShqSpace.xl,
          ShqSpace.sm,
          ShqSpace.xl,
          ShqSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(ShqRadius.pill),
                ),
              ),
            ),
            const SizedBox(height: ShqSpace.lg),
            Text(
              workbook.title,
              style: theme.textTheme.titleMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: ShqSpace.xs),
            // 当前归属：让"移动/打标签"有上下文，不用猜现在在哪儿
            Text(
              '${workbook.isUnfiled ? '未分类' : workbook.folder}'
              '${workbook.tags.isEmpty ? '' : ' · ${workbook.tags.join(' / ')}'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: ShqSpace.sm),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => closeAndRun(onRename),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sell_outlined),
              title: const Text('编辑标签'),
              onTap: () => closeAndRun(onEditTags),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined),
              title: const Text('移动到文件夹'),
              onTap: () => closeAndRun(onMoveToFolder),
            ),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('删除', style: TextStyle(color: scheme.error)),
              onTap: () => closeAndRun(onDelete),
            ),
            const Divider(),
            // 导出（2026-10-25 落地）：原题 / 笔迹 / 答题卡 三件套自由组合。
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.ios_share_outlined),
              title: const Text('导出 PDF'),
              subtitle: Text(
                '原题 / 笔迹 / 答题卡，可组合',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              onTap: () => closeAndRun(onExport),
            ),
          ],
        ),
      ),
    );
  }
}

/// 重命名对话框。返回新标题（已 trim）；取消 / 空标题返回 null。
///
/// 空标题不算"保存"：库里 `title TEXT NOT NULL`，存空串等于给用户一个
/// 没有名字的卷——宁可当作取消。
///
/// [dialogTitle] / [fieldLabel] 让"新建文件夹"复用它（同一个交互，不同文案），
/// 避免为了两个词复制一整个对话框。
Future<String?> showRenameDialog(
  BuildContext context, {
  required String initialTitle,
  String dialogTitle = '重命名',
  String fieldLabel = '标题',
}) {
  final TextEditingController controller = TextEditingController(
    text: initialTitle,
  );
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text(dialogTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: fieldLabel),
          onSubmitted: (String value) {
            final String trimmed = value.trim();
            if (trimmed.isNotEmpty) {
              Navigator.of(context).pop(trimmed);
            }
          },
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final String trimmed = controller.text.trim();
              Navigator.of(context).pop(trimmed.isEmpty ? null : trimmed);
            },
            child: const Text('保存'),
          ),
        ],
      );
    },
  );
}

/// 删除确认对话框。返回 true 才真删。
///
/// 文案说清"连带删除什么"：这一卷目录下的 PDF、缩略图、笔迹与识别记录
/// 都跟着没——删除是 T1.4 里唯一不可逆的操作，确认必须具体。
///
/// [favoriteCount] > 0 时额外说明**收藏不会跟着删**（T8.6）：收藏是跨卷快照
/// （`favorites/<id>/`），卷删了题面/笔迹/AI 对话仍在，只是「回看出处」失效。
Future<bool> showDeleteConfirmDialog(
  BuildContext context, {
  required String title,
  int favoriteCount = 0,
}) async {
  final ThemeData theme = Theme.of(context);
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('删除这一卷？'),
      content: Text(
        '《$title》删除后无法恢复。\n这一卷的 PDF、缩略图，以及之后产生的笔迹和'
        '识别记录都会一起删除。'
        '${favoriteCount > 0 ? '\n\n其中 $favoriteCount 道题已收藏：收藏夹里的题面、'
              '作答与 AI 对话是独立快照，会保留下来（「回到出处」将不可用）。' : ''}',
        style: theme.textTheme.bodyMedium,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(favoriteCount > 0 ? '删除（保留 $favoriteCount 道收藏）' : '删除'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 编辑标签 **+ 书签颜色**（同一个弹窗）。
///
/// 2026-10-24 用户口径：改标签和挑颜色是一件事——标签在书架上就是一枚彩色
/// 书签，分开两个入口等于让人把同一个决定做两遍。所以颜色区就长在这个
/// 对话框里，跟着输入框里的内容实时走（打完逗号，色板立刻多一行）。
///
/// 返回规范化后的标签列表；取消返回 null。颜色不走返回值——它按标签名存
/// （[onPickColor]），点一个色点就落盘，用户能马上看到书签变色。
Future<List<String>?> showTagsDialog(
  BuildContext context, {
  required List<String> initial,
  Map<String, String> colors = const <String, String>{},
  void Function(String tag, String hex)? onPickColor,
}) {
  return showDialog<List<String>>(
    context: context,
    builder: (BuildContext context) => _TagsDialog(
      initial: initial,
      colors: colors,
      onPickColor: onPickColor,
    ),
  );
}

class _TagsDialog extends StatefulWidget {
  const _TagsDialog({
    required this.initial,
    required this.colors,
    this.onPickColor,
  });

  final List<String> initial;
  final Map<String, String> colors;
  final void Function(String tag, String hex)? onPickColor;

  @override
  State<_TagsDialog> createState() => _TagsDialogState();
}

class _TagsDialogState extends State<_TagsDialog> {
  late final TextEditingController _controller;
  late Map<String, String> _colors;
  List<String> _tags = const <String>[];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: WorkbookTags.toEditable(widget.initial),
    );
    _controller.addListener(_sync);
    _colors = Map<String, String>.of(widget.colors);
    _tags = WorkbookTags.parse(_controller.text);
  }

  @override
  void dispose() {
    _controller.removeListener(_sync);
    _controller.dispose();
    super.dispose();
  }

  /// 输入框一变就重算标签列表：颜色区要跟"正在打的这行"同步，
  /// 否则用户加完标签还得关掉再开一次才能配色。
  void _sync() {
    final List<String> next = WorkbookTags.parse(_controller.text);
    if (next.length == _tags.length) {
      bool same = true;
      for (int i = 0; i < next.length; i++) {
        if (next[i] != _tags[i]) {
          same = false;
          break;
        }
      }
      if (same) {
        return;
      }
    }
    setState(() => _tags = next);
  }

  Color _colorOf(String tag) {
    final String hex = _colors[tag] ?? '';
    return shqHexColor(hex.isEmpty ? defaultTagHex(tag) : hex);
  }

  void _pick(String tag, String hex) {
    setState(() => _colors[tag] = hex);
    widget.onPickColor?.call(tag, hex);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: const Text('标签'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '用逗号分隔',
                helperText:
                    '最多 ${WorkbookTags.maxCount} 个，每个 ≤${WorkbookTags.maxLength} 字',
              ),
              onSubmitted: (String value) =>
                  Navigator.of(context).pop(WorkbookTags.parse(value)),
            ),
            if (widget.onPickColor != null) ...<Widget>[
              const SizedBox(height: ShqSpace.md),
              Text(
                '书签颜色',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: ShqSpace.xxs),
              Text(
                '同一种标签在所有卷子上都是同一个颜色。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: ShqSpace.sm),
              if (_tags.isEmpty)
                Text(
                  '先写几个标签，下面就会出现色板。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                )
              else
                for (final String tag in _tags) ...<Widget>[
                  Row(
                    children: <Widget>[
                      TagBookmark(tag: tag, color: _colorOf(tag)),
                      const SizedBox(width: ShqSpace.sm),
                      Expanded(
                        child: Text(
                          tag,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: ShqSpace.xs),
                  Wrap(
                    spacing: ShqSpace.sm,
                    runSpacing: ShqSpace.xs,
                    children: <Widget>[
                      for (final String hex in kTagPalette)
                        SwatchDot(
                          hex: hex,
                          selected:
                              (_colors[tag] ?? '').toUpperCase() ==
                              hex.toUpperCase(),
                          onTap: () => _pick(tag, hex),
                        ),
                      SwatchDot(
                        hex: defaultTagHex(tag),
                        label: '默认',
                        selected: (_colors[tag] ?? '').isEmpty,
                        onTap: () => _pick(tag, ''),
                      ),
                    ],
                  ),
                  const SizedBox(height: ShqSpace.md),
                ],
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(WorkbookTags.parse(_controller.text)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 选择文件夹。返回选中的名字（'' = 未分类）；取消返回 null。
///
/// 「新建文件夹」也在这里：不单独做一个"文件夹管理"页面 ——
/// 书架上的文件夹是**卷的归属**，不应该存在空文件夹，所以入口放在"移动"里最自然。
Future<String?> showFolderPicker(
  BuildContext context, {
  required List<ShelfFolder> folders,
  required String currentId,
}) {
  // 按"树形缩进"列出全部文件夹：嵌套之后光看名字会分不清同名文件夹。
  final List<ShelfFolderRow> rows = visibleFolderRows(folders, <String>{
    for (final ShelfFolder folder in folders) folder.id,
  });
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => SimpleDialog(
      title: const Text('移动到文件夹'),
      children: <Widget>[
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(''),
          child: Row(
            children: <Widget>[
              Icon(
                currentId.isEmpty ? Icons.check : Icons.folder_off_outlined,
                size: 18,
              ),
              const SizedBox(width: ShqSpace.sm),
              const Text('未分类'),
            ],
          ),
        ),
        for (final ShelfFolderRow row in rows)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(row.folder.id),
            child: Padding(
              padding: EdgeInsets.only(left: row.depth * 16),
              child: Row(
                children: <Widget>[
                  Icon(
                    currentId == row.folder.id
                        ? Icons.check
                        : Icons.folder_outlined,
                    size: 18,
                  ),
                  const SizedBox(width: ShqSpace.sm),
                  Flexible(
                    child: Text(
                      row.folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ShqSpace.lg),
          child: Text(
            '新建文件夹请用书架上方的「新建」',
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      ],
    ),
  );
}
