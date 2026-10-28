import 'package:flutter/material.dart';
import 'package:shuaqi/ui/settings/user_notice_content.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 首次启动的「用户须知」弹窗。
///
/// 只由 `ShuaqiApp` 在**全新安装**且未确认时调用；内容复用设置页同一份
/// [UserNoticeContent]，不在这里再写一遍文案。
///
/// 返回值：true = 用户勾选并同意；false = 用户点「暂不使用」（调用方退出应用）。
Future<bool> showUserNoticeDialog(BuildContext context) async {
  final bool? accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) => const _UserNoticeDialog(),
  );
  return accepted ?? false;
}

class _UserNoticeDialog extends StatefulWidget {
  const _UserNoticeDialog();

  @override
  State<_UserNoticeDialog> createState() => _UserNoticeDialogState();
}

class _UserNoticeDialogState extends State<_UserNoticeDialog> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Size screen = MediaQuery.sizeOf(context);
    return PopScope(
      canPop: false,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: ShqSpace.lg,
          vertical: ShqSpace.lg,
        ),
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShqRadius.xl),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 760,
            maxHeight: screen.height * 0.88,
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    ShqSpace.lg,
                    ShqSpace.lg,
                    ShqSpace.lg,
                    ShqSpace.md,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(ShqRadius.md),
                        ),
                        child: Icon(
                          Icons.menu_book_outlined,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: ShqSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '使用前请知悉',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '和「设置 → 关于 → 用户须知」是同一份内容；'
                              '确认后不再弹出，可随时到设置里查看。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                const Flexible(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(horizontal: ShqSpace.lg),
                    child: UserNoticeContent(showIntro: false),
                  ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    ShqSpace.lg,
                    ShqSpace.sm,
                    ShqSpace.lg,
                    ShqSpace.lg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      InkWell(
                        borderRadius: BorderRadius.circular(ShqRadius.sm),
                        onTap: () => setState(() => _checked = !_checked),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: <Widget>[
                              Checkbox(
                                value: _checked,
                                onChanged: (bool? value) =>
                                    setState(() => _checked = value ?? false),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '我已阅读并知悉以上内容',
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: ShqSpace.sm),
                      Row(
                        children: <Widget>[
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text('暂不使用'),
                          ),
                          const Spacer(),
                          FilledButton(
                            onPressed: _checked
                                ? () => Navigator.of(context).pop(true)
                                : null,
                            child: const Text('同意并继续'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '选择「暂不使用」会退出应用；下次打开会再次提示。',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                    ],
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
