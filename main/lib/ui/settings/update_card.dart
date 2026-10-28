import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/domain/app/app_release.dart';
import 'package:shuaqi/domain/app/backup_file.dart';
import 'package:shuaqi/domain/app/cache_report.dart';
import 'package:shuaqi/state/settings_providers.dart';
import 'package:shuaqi/state/update_providers.dart';
import 'package:shuaqi/ui/settings/backup_actions.dart';
import 'package:shuaqi/ui/settings/cache_sheet.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 版本说明页顶部的「检查更新」卡片（0.1.3）。
///
/// 状态机全部来自 [updateProvider]：检查中 / 已是最新 / 发现新版本 /
/// 备份中 / 下载中 / 下载完成 / 安装中 / 出错。
class UpdateCard extends ConsumerStatefulWidget {
  const UpdateCard({super.key});

  @override
  ConsumerState<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends ConsumerState<UpdateCard> {
  bool _checkingManual = false;

  Future<void> _check() async {
    if (_checkingManual) {
      return;
    }
    setState(() => _checkingManual = true);
    try {
      await ref.read(updateProvider.notifier).checkNow();
    } on Object {
      // 错误已写进 state.error，卡片里展示。
    } finally {
      if (mounted) {
        setState(() => _checkingManual = false);
      }
    }
  }

  Future<void> _openRelease(AppRelease release) async {
    final String url = release.htmlUrl.isNotEmpty
        ? release.htmlUrl
        : 'https://github.com/Terryliu001/SHUA_QI/releases';
    try {
      await ref.read(mediaStoreChannelProvider).openUrl(url);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('打不开浏览器；可以在仓库 Releases 里查看')),
        );
      }
    }
  }

  Future<void> _openHistory() async {
    try {
      await ref
          .read(mediaStoreChannelProvider)
          .openUrl('https://github.com/Terryliu001/SHUA_QI/releases');
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('打不开浏览器；仓库地址在设置页底部')));
      }
    }
  }

  /// 更新前确认弹窗：把「先自动备份」和「从备份恢复」都放在同一个弹窗里。
  ///
  /// 用户点「从备份恢复…」会取消本次更新，直接打开备份列表；这样不用先退出
  /// 版本说明、再去设置里翻「存储占用」。同一弹窗里也保留「管理备份文件」，
  /// 想先看看/清理旧备份再更新的人不用绕路。
  Future<void> _startUpdate(AppRelease release) async {
    final String lastBackup = ref.read(updateProvider).lastBackupName;
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final _UpdateAction? action = await showDialog<_UpdateAction>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('更新到 v${release.version}？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '这是覆盖安装，不会删除本机数据。',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(ShqSpace.sm),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(ShqRadius.sm),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.shield_outlined,
                        size: 17,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '更新前自动备份',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '会先备份到「下载/SHUAQI」；备份失败会中止更新。'
                    '备份完成后自动下载并打开系统安装器。',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  if (lastBackup.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      '上次更新前备份：$lastBackup',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: ShqSpace.sm,
                    runSpacing: ShqSpace.xs,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: () =>
                            Navigator.of(context).pop(_UpdateAction.restore),
                        icon: const Icon(
                          Icons.settings_backup_restore,
                          size: 18,
                        ),
                        label: const Text('从备份恢复…'),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            Navigator.of(context).pop(_UpdateAction.manage),
                        icon: const Icon(Icons.folder_open_outlined, size: 18),
                        label: const Text('管理备份文件'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '更新后若数据异常，可随时从更新前备份恢复（恢复前会再留底当前数据）。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_UpdateAction.go),
            child: const Text('先备份并更新'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case _UpdateAction.restore:
        await restoreBackup(context, ref);
      case _UpdateAction.manage:
        await showCacheSheet(context, ref, focusBackup: true);
      case _UpdateAction.go:
        await ref.read(updateProvider.notifier).startUpdate();
    }
  }

  Future<void> _restoreLastBackup() async {
    final String name = ref.read(updateProvider).lastBackupName;
    if (name.isEmpty) {
      return;
    }
    List<BackupFileInfo> list = const <BackupFileInfo>[];
    try {
      list = await ref.read(backupLibraryProvider).list();
    } on Object {
      list = const <BackupFileInfo>[];
    }
    BackupFileInfo? found;
    for (final BackupFileInfo info in list) {
      if (info.name == name) {
        found = info;
        break;
      }
    }
    if (!mounted) {
      return;
    }
    if (found == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('找不到 $name（可能已被移动或删除）；可在「存储占用 → 备份文件」里查看')),
      );
      return;
    }
    await restoreBackupFromInfo(context, ref, found);
  }

  @override
  Widget build(BuildContext context) {
    final UpdateState state = ref.watch(updateProvider);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppRelease? latest = state.latest;
    final bool hasUpdate = state.hasUpdate;
    // 打开版本说明看到更新卡片即视为"已读"：把红点清掉。
    if (hasUpdate && latest != null && state.seenVersion != latest.version) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(ref.read(updateProvider.notifier).markSeen());
        }
      });
    }
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.primaryContainer.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ShqRadius.lg),
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ShqSpace.lg,
          ShqSpace.md,
          ShqSpace.lg,
          ShqSpace.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.system_update_alt, color: scheme.primary, size: 20),
                const SizedBox(width: ShqSpace.sm),
                Text(
                  '版本更新',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '当前 v${AppInfo.version}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _lastCheckedText(state.lastCheckedAt),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: ShqSpace.sm),
            if (state.checking || _checkingManual)
              Row(
                children: <Widget>[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: ShqSpace.sm),
                  Text(
                    '正在检查 GitHub Releases…',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              )
            else if (hasUpdate && latest != null) ...<Widget>[
              Text(
                '发现新版本 v${latest.version}',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${_dateText(latest.publishedAt)}'
                '${latest.apkSize > 0 ? ' · ${formatBytes(latest.apkSize)}' : ''}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (latest.notes.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: ShqSpace.sm),
                Text(
                  latest.notes.trim(),
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.55),
                ),
              ],
              const SizedBox(height: ShqSpace.sm),
              if (state.backingUp)
                _inlineProgress(theme, '正在备份更新前数据…（备份失败会中止更新）')
              else if (state.downloading)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    LinearProgressIndicator(
                      value: state.totalBytes > 0
                          ? state.downloadProgress
                          : null,
                      minHeight: 6,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Text(
                          '下载中 ${(state.downloadProgress * 100).round()}%'
                          ' · ${formatBytes(state.downloaded)}'
                          '${state.totalBytes > 0 ? ' / ${formatBytes(state.totalBytes)}' : ''}',
                          style: theme.textTheme.labelSmall,
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => unawaited(
                            ref.read(updateProvider.notifier).cancelDownload(),
                          ),
                          child: const Text('取消'),
                        ),
                      ],
                    ),
                  ],
                )
              else if (state.installing)
                _inlineProgress(theme, '正在打开系统安装器…')
              else if (state.downloadedPath != null)
                Row(
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: () => unawaited(
                        ref.read(updateProvider.notifier).installDownloaded(),
                      ),
                      icon: const Icon(Icons.install_mobile, size: 18),
                      label: const Text('已下载，去安装'),
                    ),
                    const SizedBox(width: ShqSpace.sm),
                    TextButton(
                      onPressed: () => _openRelease(latest),
                      child: const Text('去 GitHub 查看'),
                    ),
                  ],
                )
              else
                Row(
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: latest.hasApk
                          ? () => unawaited(_startUpdate(latest))
                          : null,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('下载并安装'),
                    ),
                    const SizedBox(width: ShqSpace.sm),
                    OutlinedButton(
                      onPressed: () => _openRelease(latest),
                      child: const Text('去 GitHub 查看'),
                    ),
                  ],
                ),
              const SizedBox(height: 4),
              Text(
                '更新是覆盖安装，不会删除本机数据；点「下载并安装」会先把数据备份到「下载/SHUAQI」。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ] else ...<Widget>[
              Text(
                latest == null
                    ? '还没有检查过更新。'
                    : latest.isNewerThan(AppInfo.version) && !latest.hasApk
                    ? '发现新版本 v${latest.version}，但这个 Release 里没有 APK；请去 GitHub 查看。'
                    : '当前已是最新版本 v${AppInfo.version}。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: ShqSpace.sm),
              Row(
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: _check,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('检查更新'),
                  ),
                  if (latest != null &&
                      latest.isNewerThan(AppInfo.version) &&
                      !latest.hasApk) ...<Widget>[
                    const SizedBox(width: ShqSpace.sm),
                    TextButton(
                      onPressed: () => _openRelease(latest),
                      child: const Text('去 GitHub 查看'),
                    ),
                  ],
                ],
              ),
            ],
            if (state.error != null) ...<Widget>[
              const SizedBox(height: ShqSpace.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(ShqSpace.sm),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(ShqRadius.sm),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      state.error!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onErrorContainer,
                        height: 1.5,
                      ),
                    ),
                    if (state.error!.contains('允许')) ...<Widget>[
                      const SizedBox(height: 4),
                      TextButton(
                        onPressed: () => unawaited(
                          ref
                              .read(updateProvider.notifier)
                              .openUnknownSources(),
                        ),
                        child: const Text('去允许安装未知应用'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: ShqSpace.sm),
            Divider(height: 1, color: scheme.outlineVariant),
            const SizedBox(height: ShqSpace.sm),
            _RestoreGuide(
              lastBackupName: state.lastBackupName,
              lastBackupAt: state.lastBackupAt,
              onRestore: () => unawaited(_restoreLastBackup()),
              onRestoreAny: () => unawaited(restoreBackup(context, ref)),
              onManageBackups: () =>
                  unawaited(showCacheSheet(context, ref, focusBackup: true)),
              onOpenHistory: () => unawaited(_openHistory()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inlineProgress(ThemeData theme, String text) {
    return Row(
      children: <Widget>[
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: ShqSpace.sm),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}

/// 更新页里的「数据安全 / 恢复指导」。
class _RestoreGuide extends StatelessWidget {
  const _RestoreGuide({
    required this.lastBackupName,
    required this.lastBackupAt,
    required this.onRestore,
    required this.onRestoreAny,
    required this.onManageBackups,
    required this.onOpenHistory,
  });

  final String lastBackupName;
  final int lastBackupAt;
  final VoidCallback onRestore;
  final VoidCallback onRestoreAny;
  final VoidCallback onManageBackups;
  final VoidCallback onOpenHistory;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.shield_outlined, size: 17, color: scheme.primary),
            const SizedBox(width: 6),
            Text(
              '数据安全与恢复',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '更新不会删除本机数据；更新前会自动备份到「下载/SHUAQI」。'
          '如果更新后数据异常，不用先去设置里翻：下面可以直接从备份恢复，'
          '恢复前会先留底当前数据，再替换并重启。',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.55,
          ),
        ),
        const SizedBox(height: ShqSpace.sm),
        Wrap(
          spacing: ShqSpace.sm,
          runSpacing: ShqSpace.xs,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: onRestoreAny,
              icon: const Icon(Icons.settings_backup_restore, size: 18),
              label: const Text('从备份恢复…'),
            ),
            OutlinedButton.icon(
              onPressed: onManageBackups,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('管理备份文件'),
            ),
          ],
        ),
        if (lastBackupName.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(ShqSpace.sm),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShqRadius.sm),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '上次更新前备份',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  lastBackupName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  lastBackupAt > 0 ? _dateText(lastBackupAt) : '',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                  ),
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: ShqSpace.sm,
                  children: <Widget>[
                    TextButton(
                      onPressed: onRestore,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 28),
                      ),
                      child: const Text('恢复这份备份'),
                    ),
                    TextButton(
                      onPressed: onManageBackups,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 28),
                      ),
                      child: const Text('管理全部备份'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 2),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: onOpenHistory,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 28),
            ),
            child: const Text('查看历史版本（GitHub Releases）'),
          ),
        ),
      ],
    );
  }
}

String _lastCheckedText(int millis) {
  if (millis <= 0) {
    return '还没有检查过更新';
  }
  return '上次检查：${_dateText(millis)}';
}

String _dateText(int millis) {
  final DateTime date = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}

enum _UpdateAction { restore, manage, go }
