import 'package:flutter/material.dart';
import 'package:shuaqi/domain/app/about_content.dart';
import 'package:shuaqi/ui/settings/notice_restore_card.dart';
import 'package:shuaqi/ui/settings/settings_subpage.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 用户须知的**共享正文**（设置页与首次启动弹窗渲染同一份）。
///
/// 0.1.3 新增：首次安装要弹窗告知，内容必须和「设置 → 关于 → 用户须知」
/// 完全一致。把渲染抽到这里，两处只共用 [kUserNotice] 数据，不各写一套文案。
class UserNoticeContent extends StatelessWidget {
  const UserNoticeContent({
    super.key,
    this.showIntro = true,
    this.showRestoreCard = true,
  });

  /// 弹窗里标题已经说明了"和设置里同一份"，可以不再重复开场白。
  final bool showIntro;

  /// 是否显示「从备份恢复」入口（首次启动弹窗与设置页都显示）。
  final bool showRestoreCard;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showIntro)
          const _NoticeIntro(
            '这一页把"应用拿了你什么、数据去了哪、AI 是怎么被调用的"一次说清。'
            '任何一条与实际行为不符，都以实际行为为准，并请通过「用户反馈」告诉我们。',
          ),
        if (showRestoreCard) const NoticeRestoreCard(),
        for (final NoticeSection section in kUserNotice)
          NoticeSectionCard(section: section),
        const SizedBox(height: ShqSpace.lg),
      ],
    );
  }
}

/// 一个须知板块。
class NoticeSectionCard extends StatelessWidget {
  const NoticeSectionCard({super.key, required this.section});

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
              if (section.bullets.isNotEmpty)
                const SizedBox(height: ShqSpace.sm),
              for (final String bullet in section.bullets)
                SubPageBullet(bullet),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeIntro extends StatelessWidget {
  const _NoticeIntro(this.text);

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
