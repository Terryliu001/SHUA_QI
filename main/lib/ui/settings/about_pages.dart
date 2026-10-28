import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/domain/app/about_content.dart';
import 'package:shuaqi/state/update_providers.dart';
import 'package:shuaqi/ui/settings/settings_subpage.dart';
import 'package:shuaqi/ui/settings/update_card.dart';
import 'package:shuaqi/ui/settings/user_notice_content.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 关于 → 版本说明。
///
/// 0.1.3 改版：顶部是**版本检测/更新**卡片；下面只显示当前版本信息，
/// 老版本统一给「查看历史版本（GitHub Releases）」入口。
class ReleaseNotesPage extends ConsumerStatefulWidget {
  const ReleaseNotesPage({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<ReleaseNotesPage> createState() => _ReleaseNotesPageState();
}

class _ReleaseNotesPageState extends ConsumerState<ReleaseNotesPage> {
  @override
  void initState() {
    super.initState();
    // 打开即清红点；同时如果太久没查，静默补一次检查。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(ref.read(updateProvider.notifier).markSeen());
      unawaited(ref.read(updateProvider.notifier).checkIfDue());
    });
  }

  @override
  Widget build(BuildContext context) {
    final ReleaseNote current = kReleaseNotes.firstWhere(
      (ReleaseNote note) => note.version == AppInfo.version,
      orElse: () => kReleaseNotes.first,
    );
    return SettingsSubPageScaffold(
      page: SettingsSubPage.releaseNotes,
      subtitle: '${AppInfo.name} ${AppInfo.version} · 更新记录与已知限制',
      onClose: widget.onClose,
      child: SettingsSubPageBody(
        children: <Widget>[
          const UpdateCard(),
          const SizedBox(height: ShqSpace.lg),
          Text(
            '当前版本 v${current.version}',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          _ReleaseCard(note: current, current: true),
          const SizedBox(height: ShqSpace.lg),
        ],
      ),
    );
  }
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({required this.note, required this.current});

  final ReleaseNote note;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: ShqSpace.md),
      child: Card(
        margin: EdgeInsets.zero,
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
                  Text(
                    'v${note.version}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: ShqSpace.sm),
                  Text(
                    note.date,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (current)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: ShqSpace.sm,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(ShqRadius.pill),
                      ),
                      child: Text(
                        '当前版本',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              if (note.added.isNotEmpty)
                _NoteBlock(title: '新增', items: note.added),
              if (note.changed.isNotEmpty)
                _NoteBlock(title: '调整', items: note.changed),
              if (note.fixed.isNotEmpty)
                _NoteBlock(title: '修复', items: note.fixed),
              if (note.limits.isNotEmpty)
                _NoteBlock(
                  title: '已知限制',
                  items: note.limits,
                  color: ShqPalette.unclear,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoteBlock extends StatelessWidget {
  const _NoteBlock({required this.title, required this.items, this.color});

  final String title;
  final List<String> items;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color accent = color ?? scheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: ShqSpace.md, bottom: ShqSpace.xs),
          child: Row(
            children: <Widget>[
              Container(
                width: 3,
                height: 12,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: ShqSpace.sm),
              Text(
                title,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
        for (final String item in items) SubPageBullet(item, color: accent),
      ],
    );
  }
}

/// 关于 → 用户须知（只读）。
class UserNoticePage extends StatelessWidget {
  const UserNoticePage({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SettingsSubPageScaffold(
      page: SettingsSubPage.userNotice,
      subtitle: '权限 · AI 与 API 调度 · 数据在哪 · 隐私与限制',
      onClose: onClose,
      child: const SettingsSubPageBody(children: <Widget>[UserNoticeContent()]),
    );
  }
}
