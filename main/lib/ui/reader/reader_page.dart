import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 阅读器（T1.5 落地）。当前把「有效阅读偏好」算出来显示，用来证明一条产品规则：
///
/// **深色模式与纸感互斥**（§6.9.3）——深色下强制退回 `original`，
/// 由统一暗色遮罩处理；否则暖色纸 + 深色底会糊成一片。
class ReaderPage extends ConsumerWidget {
  const ReaderPage({super.key, required this.workbookId});

  final String workbookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ReaderPrefs stored = ref.watch(readerPrefsProvider);
    final ReaderPrefs effective = stored.forSurfaceBrightness(
      isDark: theme.brightness == Brightness.dark,
    );

    return Scaffold(
      appBar: AppBar(title: Text('阅读器 · $workbookId')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ShqLayout.maxReadingWidth),
          child: Padding(
            padding: const EdgeInsets.all(ShqSpace.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text('T1.5 双模式阅读器待实现', style: theme.textTheme.titleLarge),
                const SizedBox(height: ShqSpace.md),
                Text(
                  '模式 ${effective.mode.name} · '
                  '纸 ${effective.style.name} · '
                  '强度 ${effective.intensity}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: ShqSpace.sm),
                Text(
                  theme.brightness == Brightness.dark
                      ? '当前是深色，纸感已自动退回 original。'
                      : '当前是浅色，纸感按设置生效。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
