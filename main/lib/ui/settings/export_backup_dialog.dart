import 'package:flutter/material.dart';
import 'package:shuaqi/app/backup/backup_service.dart';
import 'package:shuaqi/domain/app/backup_naming.dart';

/// 「导出备份」的命名弹窗（0.1.3）。
///
/// 与「从备份恢复」一样先弹窗：显示会备份什么、允许改文件名、重名自动加 `-2`。
/// 返回**不含 `.zip`** 的基名；用户取消返回 null。
Future<String?> showExportBackupDialog(
  BuildContext context, {
  required BackupCounts counts,
  required String defaultName,
  required Set<String> existingNames,
}) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => _ExportBackupDialog(
      counts: counts,
      defaultName: defaultName,
      existingNames: existingNames,
    ),
  );
}

class _ExportBackupDialog extends StatefulWidget {
  const _ExportBackupDialog({
    required this.counts,
    required this.defaultName,
    required this.existingNames,
  });

  final BackupCounts counts;
  final String defaultName;
  final Set<String> existingNames;

  @override
  State<_ExportBackupDialog> createState() => _ExportBackupDialogState();
}

class _ExportBackupDialogState extends State<_ExportBackupDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.defaultName,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String base = sanitizeBackupBaseName(_controller.text);
    if (!isValidBackupBaseName(base)) {
      setState(() => _error = '文件名不能为空，也不能只有符号');
      return;
    }
    final String full = dedupeBackupName(base, widget.existingNames);
    Navigator.of(context).pop(backupBaseNameOf(full));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return AlertDialog(
      title: const Text('导出备份'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '会把卷子、笔迹、切题结果、收藏、作答记录打成一个 zip。',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
            ),
            const SizedBox(height: 6),
            Text(
              '包含：${widget.counts.summary}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_error != null) {
                  setState(() => _error = null);
                }
              },
              decoration: InputDecoration(
                labelText: '文件名',
                suffixText: '.zip',
                helperText: '可以改成你认得出的名字；重名会自动加 -2',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '保存到「下载/SHUAQI」。卸载应用不会删除它，换设备也能带过去。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('导出')),
      ],
    );
  }
}
