import 'package:flutter/material.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/domain/app/about_content.dart';
import 'package:shuaqi/ui/settings/settings_subpage.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 关于 → 版本说明（只读）。
///
/// 一条版本一张卡片：版本号 + 日期 + 「当前版本」标；下面是四段
/// （新增 / 调整 / 修复 / 已知限制）。已知限制**必显示**——
/// 它是这一版最容易被误解的地方，藏起来只会变成"用户以为坏了"。
class ReleaseNotesPage extends StatelessWidget {
  const ReleaseNotesPage({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SettingsSubPageScaffold(
      page: SettingsSubPage.releaseNotes,
      subtitle: '${AppInfo.name} ${AppInfo.version} · 更新记录与已知限制',
      onClose: onClose,
      child: SettingsSubPageBody(
        children: <Widget>[
          const _Intro(
            '每条记录只写这一版「真的」能做什么、修好了什么、还做不到什么。'
            '没有做的功能不会出现在这里。',
          ),
          for (int i = 0; i < kReleaseNotes.length; i += 1)
            _ReleaseCard(note: kReleaseNotes[i], current: i == 0),
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
      child: SettingsSubPageBody(
        children: <Widget>[
          const _Intro(
            '这一页把"应用拿了你什么、数据去了哪、AI 是怎么被调用的"一次说清。'
            '任何一条与实际行为不符，都以实际行为为准，并请通过「用户反馈」告诉我们。',
          ),
          for (final NoticeSection section in kUserNotice)
            _NoticeCard(section: section),
          const SizedBox(height: ShqSpace.lg),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.section});

  final NoticeSection section;

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
            ShqSpace.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                section.title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                section.summary,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.primary,
                  height: 1.6,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (section.bullets.isNotEmpty) const SizedBox(height: ShqSpace.sm),
              for (final String bullet in section.bullets) SubPageBullet(bullet),
            ],
          ),
        ),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
          height: 1.65,
        ),
      ),
    );
  }
}
