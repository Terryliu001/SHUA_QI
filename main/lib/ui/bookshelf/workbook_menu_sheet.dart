import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/workbook.dart';
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
  required VoidCallback onDelete,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) => _WorkbookMenuSheet(
      workbook: workbook,
      onRename: onRename,
      onDelete: onDelete,
    ),
  );
}

class _WorkbookMenuSheet extends StatelessWidget {
  const _WorkbookMenuSheet({
    required this.workbook,
    required this.onRename,
    required this.onDelete,
  });

  final Workbook workbook;
  final VoidCallback onRename;
  final VoidCallback onDelete;

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
            const SizedBox(height: ShqSpace.sm),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => closeAndRun(onRename),
            ),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('删除', style: TextStyle(color: scheme.error)),
              onTap: () => closeAndRun(onDelete),
            ),
            const Divider(),
            // 置灰项：不可点 + 锁形角标 + 一句规划位置
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.ios_share_outlined,
                color: scheme.outlineVariant,
              ),
              title: Text(
                '导出',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: scheme.outline,
                ),
              ),
              subtitle: Text(
                'PDF / 墨迹层 / zip 备份 · 规划在 T7',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              trailing: Icon(
                Icons.lock_outline,
                size: 18,
                color: scheme.outlineVariant,
              ),
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
Future<String?> showRenameDialog(
  BuildContext context, {
  required String initialTitle,
}) {
  final TextEditingController controller = TextEditingController(
    text: initialTitle,
  );
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '标题'),
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
/// 文案说清"连带删除什么"：这一卷目录下的 PDF、缩略图、将来的笔迹与
/// 识别记录都跟着没——删除是 T1.4 里唯一不可逆的操作，确认必须具体。
Future<bool> showDeleteConfirmDialog(
  BuildContext context, {
  required String title,
}) async {
  final ThemeData theme = Theme.of(context);
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('删除这一卷？'),
      content: Text(
        '《$title》删除后无法恢复。\n这一卷的 PDF、缩略图，以及之后产生的笔迹和'
        '识别记录都会一起删除。',
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
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return result ?? false;
}
