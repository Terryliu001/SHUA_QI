import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/ui/settings/backup_actions.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 用户须知里的「从备份恢复」入口（首次启动弹窗 + 设置里的用户须知共用）。
///
/// 为什么放在用户须知里：重装/换设备的人第一眼就该知道“数据可以先恢复”，
/// 而不是先点同意、再满设置找「存储占用 → 备份文件」。
class NoticeRestoreCard extends ConsumerWidget {
  const NoticeRestoreCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(top: ShqSpace.md),
      color: scheme.secondaryContainer.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ShqRadius.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ShqLayout.gutter,
          ShqSpace.md,
          ShqLayout.gutter,
          ShqSpace.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.settings_backup_restore,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  '从备份恢复（可选）',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '如果你刚从旧设备/旧版本重装，或更新前导出过备份，可以先把数据恢复回来。'
              '恢复会覆盖本机当前数据；覆盖前会先留底一份，恢复完成后需要重启。'
              '首次启动也可以先恢复，再点下方「同意并继续」。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () => unawaited(_confirmAndRestore(context, ref)),
              icon: const Icon(Icons.settings_backup_restore, size: 18),
              label: const Text('从备份恢复…'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmAndRestore(BuildContext context, WidgetRef ref) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('从备份恢复？'),
        content: Text(
          '恢复会替换本机当前的全部数据（卷、笔迹、收藏、记录）。\n\n'
          '恢复前会先把当前数据留底一份；恢复完成后需要重启应用。\n'
          '如果备份文件不在列表里，可以在下一步点「从文件选择」。',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.6),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('选择备份…'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) {
      return;
    }
    await restoreBackup(context, ref);
  }
}
