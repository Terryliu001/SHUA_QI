import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/domain/ai/usage.dart';
import 'package:shuaqi/domain/app/accent.dart';
import 'package:shuaqi/domain/reader/paper_tint.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/state/accent_provider.dart';
import 'package:shuaqi/state/ai_providers.dart';
import 'package:shuaqi/state/ink_tool_provider.dart';
import 'package:shuaqi/state/reader_prefs_providers.dart';
import 'package:shuaqi/state/theme_mode_provider.dart';
import 'package:shuaqi/state/ui_prefs_provider.dart';
import 'package:shuaqi/state/update_providers.dart';
import 'package:shuaqi/ui/reader/debug_hud.dart';
import 'package:shuaqi/ui/settings/about_pages.dart';
import 'package:shuaqi/ui/settings/ai_settings_sheet.dart';
import 'package:shuaqi/ui/settings/ai_usage_sheet.dart';
import 'package:shuaqi/ui/settings/backup_actions.dart';
import 'package:shuaqi/ui/settings/cache_sheet.dart';
import 'package:shuaqi/ui/settings/feedback_page.dart';
import 'package:shuaqi/ui/settings/guide_page.dart';
import 'package:shuaqi/ui/settings/settings_subpage.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';
import 'package:shuaqi/ui/widgets/soft_icon.dart';

/// 设置页（T6.1：外观 + 阅读默认 + AI 配置；2026-10-26 起再管数据与开发者选项）。
///
/// 设计纪律（项目一贯原则）：**能点但没反应是假功能**。所以这一页只有两种块：
/// 1. 真实生效的（主题模式、阅读默认、AI 配置、缓存清理、备份、文字模式）——
///    写了立刻生效；
/// 2. 明确说明的（反馈通道未接通）——告诉用户它到哪一步了。
///
/// ## 2026-10-23 设计收尾（v3）
/// - **每行有图标 + 说明**：设置不是一串开关，而是一份"这个应用怎么工作"的清单；
/// - 分组标题与卡片同一条竖线（16dp），标题降为 onSurfaceVariant；
/// - 行与行之间用**发丝线**分隔（缩进 64dp 对齐文字），不再靠间距硬撑；
/// - 主题 / 默认模式改成**整宽分段选择器**（图标 + 文字），比 Material 默认的
///   紧凑 segmented button 更适合平板；
/// - 纸感增加**真实预览块**：选什么纸、什么强度，直接看到"一页纸"。
///
/// ## 2026-10-26：关于下面挂三个子页
/// 「版本说明 / 用户须知 / 用户反馈」是**应用内二级页**（`SettingsSubPage`），
/// 不是路由：push 全屏路由会把左边的导航栏一起盖住，用户会以为退出了应用。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// 用户在本页改过的阅读默认。null = 还没改过，用库里加载的值。
  /// 不自动同步回库——写由交互触发，见 [_writeDefaults]。
  ReaderPrefs? _draft;

  /// 当前打开的二级页（null = 只看设置本体）。
  SettingsSubPage? _sub;

  /// 版本号连击次数（开发者选项解锁用）。
  int _versionTaps = 0;

  Future<void> _writeDefaults(ReaderPrefs next) async {
    setState(() => _draft = next);
    await ref.read(readerPrefsStoreProvider).saveDefaults(next);
    ref.invalidate(readerDefaultsProvider);
  }

  Future<void> _openAiSettings(LlmConfig config) async {
    final bool saved = await showAiSettingsSheet(context, initial: config);
    if (saved) {
      ref.invalidate(aiConfigProvider);
    }
  }

  void _openSub(SettingsSubPage page) {
    setState(() => _sub = page);
  }

  /// 版本号连击：8 次解锁开发者选项。
  ///
  /// 中途给一次提示（从第 5 次起），免得用户以为点坏了；
  /// 解锁后弹一句明确的话，别让人自己猜"多出来的这一行是什么"。
  Future<void> _onVersionTap() async {
    final int taps = _versionTaps + 1;
    if (taps >= kDevUnlockTaps) {
      setState(() => _versionTaps = 0);
      await ref.read(devOptionsUnlockedProvider.notifier).unlock();
      if (!mounted) {
        return;
      }
      _showTip('开发者选项已打开');
      return;
    }
    setState(() => _versionTaps = taps);
    if (taps == kDevUnlockHintFrom) {
      _showTip('再点 ${kDevUnlockTaps - taps} 次打开开发者选项');
    }
  }

  void _showTip(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1600),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final SettingsSubPage? sub = _sub;
    // 0.1.3：二级页不再替换整个设置页，而是盖在它上面。
    //
    // 旧实现 `if (sub != null) return Scaffold(...)` 会让下面的设置 ListView
    // 被销毁，返回时重新创建一个从顶部开始的新列表——用户滑到「关于」点进
    // 版本说明再返回，就回到了页面顶端（反馈里的"割裂"）。
    // 现在设置主体一直挂着（Offstage 只是不画），返回时滚动位置和页面状态都在。
    return PopScope(
      canPop: sub == null,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _sub != null) {
          setState(() => _sub = null);
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Offstage(
            offstage: sub != null,
            child: Scaffold(
              appBar: AppBar(title: const Text('设置')),
              body: SafeArea(child: _settingsBody()),
            ),
          ),
          if (sub != null)
            Positioned.fill(
              child: Scaffold(
                appBar: AppBar(title: Text(sub.title)),
                body: SafeArea(child: _subBody(sub)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _subBody(SettingsSubPage sub) {
    switch (sub) {
      case SettingsSubPage.guide:
        return GuidePage(onClose: () => setState(() => _sub = null));
      case SettingsSubPage.releaseNotes:
        return ReleaseNotesPage(onClose: () => setState(() => _sub = null));
      case SettingsSubPage.userNotice:
        return UserNoticePage(onClose: () => setState(() => _sub = null));
      case SettingsSubPage.feedback:
        return FeedbackPage(onClose: () => setState(() => _sub = null));
    }
  }

  Widget _settingsBody() {
    final ThemeData theme = Theme.of(context);
    final ThemeMode themeMode = ref.watch(themeModeProvider);
    final ShqAccent accent = ref.watch(accentProvider);
    final bool iconLabels = ref.watch(iconLabelsProvider);
    final bool devUnlocked = ref.watch(devOptionsUnlockedProvider);
    final bool hasUpdate = ref.watch(updateBadgeProvider);
    final ReaderPrefs defaults =
        _draft ??
        ref
            .watch(readerDefaultsProvider)
            .maybeWhen<ReaderPrefs?>(
              data: (ReaderPrefs value) => value,
              orElse: () => null,
            ) ??
        ReaderPrefs.defaults;
    final LlmConfig aiConfig = ref
        .watch(aiConfigProvider)
        .maybeWhen<LlmConfig>(
          data: (LlmConfig value) => value,
          orElse: () => LlmConfig.empty,
        );
    final AiUsageSnapshot aiUsage = ref
        .watch(aiUsageProvider)
        .maybeWhen<AiUsageSnapshot>(
          data: (AiUsageSnapshot value) => value,
          orElse: () => AiUsageSnapshot.empty,
        );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ShqLayout.maxFormWidth),
        child: ListView(
          padding: const EdgeInsets.only(bottom: ShqSpace.xxl),
          children: <Widget>[
            _Section(
              title: '外观',
              children: <Widget>[
                _Block(
                  icon: Icons.brightness_6_outlined,
                  title: '主题',
                  subtitle: '深色只影响界面骨架，不影响卷面配色',
                  child: _ChoiceGroup<ThemeMode>(
                    options: const <_Choice<ThemeMode>>[
                      _Choice<ThemeMode>(
                        value: ThemeMode.system,
                        label: '跟随系统',
                        icon: Icons.brightness_auto_outlined,
                      ),
                      _Choice<ThemeMode>(
                        value: ThemeMode.light,
                        label: '浅色',
                        icon: Icons.light_mode_outlined,
                      ),
                      _Choice<ThemeMode>(
                        value: ThemeMode.dark,
                        label: '深色',
                        icon: Icons.dark_mode_outlined,
                      ),
                    ],
                    selected: themeMode,
                    onSelected: (ThemeMode mode) => unawaited(
                      ref.read(themeModeProvider.notifier).set(mode),
                    ),
                  ),
                ),
                const _Hairline(),
                _Block(
                  icon: Icons.palette_outlined,
                  title: '色系',
                  subtitle: '${accent.label} · ${accent.hint}',
                  child: _AccentPicker(
                    selected: accent,
                    onSelected: (ShqAccent value) =>
                        unawaited(ref.read(accentProvider.notifier).set(value)),
                  ),
                ),
                const _Hairline(),
                _SettingsRow(
                  icon: Icons.label_outline,
                  title: '文字模式',
                  subtitle: iconLabels
                      ? '顶栏与工具栏的图标旁会显示功能文字'
                      : '顶栏与工具栏只显示图标（长按有说明）',
                  trailing: Switch(
                    value: iconLabels,
                    onChanged: (bool value) => unawaited(
                      ref.read(iconLabelsProvider.notifier).set(value),
                    ),
                  ),
                ),
                const _Hairline(),
                const _Note(
                  '卷面配色在「阅读默认」里单独选：原图 = 白底黑字，夜读 = 黑底白字。'
                  '两者互不影响，深色界面下也能看白底黑字的卷子。'
                  '色系只管按钮、选中态这类可点元素的颜色，纸感与判题三色不变。',
                ),
              ],
            ),
            _Section(
              title: '阅读默认',
              children: <Widget>[
                _Block(
                  icon: Icons.menu_book_outlined,
                  title: '默认模式',
                  subtitle: '新打开的卷子用哪种翻页方式',
                  child: _ChoiceGroup<ViewMode>(
                    options: const <_Choice<ViewMode>>[
                      _Choice<ViewMode>(
                        value: ViewMode.paged,
                        label: '分页',
                        icon: Icons.auto_stories_outlined,
                      ),
                      _Choice<ViewMode>(
                        value: ViewMode.scroll,
                        label: '连续滚动',
                        icon: Icons.view_day_outlined,
                      ),
                    ],
                    selected: defaults.mode,
                    onSelected: (ViewMode mode) =>
                        _writeDefaults(defaults.copyWith(mode: mode)),
                  ),
                ),
                const _Hairline(),
                // 2026-10-24 用户第 6 条：手势模式也进"阅读默认"，
                // 与默认模式一起决定"新打开一份卷子是什么样"。
                _Block(
                  icon: Icons.gesture,
                  title: '手势模式',
                  subtitle: '开：手指只平移缩放、笔书写；关：手指也能写',
                  child: Switch(
                    value: defaults.handTool,
                    onChanged: (bool value) =>
                        _writeDefaults(defaults.copyWith(handTool: value)),
                  ),
                ),
                const _Hairline(),
                _Block(
                  icon: Icons.palette_outlined,
                  title: '默认纸感',
                  subtitle: '纸色、夜读与强度只作用在卷面背景',
                  child: _PaperPicker(
                    style: defaults.style,
                    intensity: defaults.intensity,
                    onStyle: (PaperStyle style) =>
                        _writeDefaults(defaults.copyWith(style: style)),
                  ),
                ),
                const _Hairline(),
                _Block(
                  icon: Icons.tonality_outlined,
                  title: '默认强度',
                  subtitle: '数值越高纸色越浓；原图与夜读不参与',
                  child: _IntensitySlider(
                    style: defaults.style,
                    value: defaults.intensity,
                    onChanged: (int intensity) =>
                        _writeDefaults(defaults.copyWith(intensity: intensity)),
                  ),
                ),
                const _Note('只影响之后新打开的卷；正在读的卷以阅读器内「显示」浮层为准。'),
              ],
            ),
            _Section(
              title: '书写',
              children: <Widget>[
                _SettingsRow(
                  icon: Icons.draw_outlined,
                  title: '工具条固定在顶栏',
                  subtitle: '关闭 = 右下角圆形浮钮（点开才是面板，阅读区最干净）',
                  trailing: Switch(
                    value: ref.watch(inkToolbarPinnedProvider),
                    onChanged: (bool pinned) => unawaited(
                      ref.read(inkToolbarPinnedProvider.notifier).set(pinned),
                    ),
                  ),
                ),
                const _Hairline(),
                const _Note('笔的颜色与粗细在阅读器里的工具面板中选；每支笔分别记住。'),
              ],
            ),
            _Section(
              title: 'AI 分析',
              children: <Widget>[
                _SettingsRow(
                  icon: Icons.auto_awesome_outlined,
                  title: 'AI 配置',
                  subtitle: aiConfig.validationError() == null
                      ? '已配置 · ${aiConfig.model} · ${aiConfig.maskedKey}'
                      : '未配置 · 填端点 / Key / 模型后，问 AI 与判题可用',
                  onTap: () => unawaited(_openAiSettings(aiConfig)),
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.outline,
                  ),
                ),
                const _Hairline(),
                _SettingsRow(
                  icon: Icons.data_usage_outlined,
                  title: 'AI 用量',
                  subtitle: aiUsage.summary.isEmpty
                      ? '还没有调用记录'
                      : '累计 ${aiUsage.summary.calls} 次 · '
                            '输入 ${_formatTokenCount(aiUsage.summary.tokensIn)} · '
                            '输出 ${_formatTokenCount(aiUsage.summary.tokensOut)}'
                            '${aiUsage.summary.estimatedCalls > 0 ? ' · 含估算' : ''}',
                  onTap: () {
                    ref.invalidate(aiUsageProvider);
                    unawaited(showAiUsageSheet(context));
                  },
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.outline,
                  ),
                ),
                const _Hairline(),
                const _Note(
                  '接入任意 OpenAI 兼容端点。Key 只存在本机，请求直接发往你填的地址；'
                  'AI 答案与判题都会标「AI · 请自检」，手改结论永远优先。',
                ),
              ],
            ),
            _Section(
              title: '数据',
              children: <Widget>[
                _SettingsRow(
                  icon: Icons.cleaning_services_outlined,
                  title: '存储占用',
                  subtitle: '缓存统计与清理，以及备份文件的查看、重命名、删除与恢复',
                  onTap: () => unawaited(showCacheSheet(context, ref)),
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.outline,
                  ),
                ),
                const _Hairline(),
                _SettingsRow(
                  icon: Icons.archive_outlined,
                  title: '导出备份',
                  subtitle: '可命名；把卷子、笔迹、收藏、记录打成 zip 放到「下载/SHUAQI」',
                  onTap: () {
                    unawaited(
                      exportBackup(context, ref).then<void>((bool _) {}),
                    );
                  },
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.outline,
                  ),
                ),
                const _Hairline(),
                _SettingsRow(
                  icon: Icons.settings_backup_restore,
                  title: '从备份恢复',
                  subtitle: '从备份列表选一份覆盖本机数据（替换前会先留底）',
                  onTap: () => unawaited(restoreBackup(context, ref)),
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.outline,
                  ),
                ),
                const _Hairline(),
                const _Note('数据只在本机。卸载应用会一起删掉，重要资料记得先导出备份。'),
              ],
            ),
            _Section(
              title: '关于',
              children: <Widget>[
                _AboutEntries(
                  onOpen: _openSub,
                  onVersionTap: _onVersionTap,
                  hasUpdate: hasUpdate,
                ),
              ],
            ),
            // 开发者选项：连点版本号 8 次才出现（2026-10-26 用户第 17 条）。
            if (devUnlocked)
              _Section(
                title: '开发',
                children: <Widget>[
                  if (!kReleaseMode)
                    _SettingsRow(
                      icon: Icons.speed_outlined,
                      title: '性能 HUD',
                      subtitle: '阅读器左上角显示帧耗时 / 笔画数 / 位图占用',
                      trailing: Switch(
                        value: ref.watch(debugHudProvider),
                        onChanged: (bool _) =>
                            ref.read(debugHudProvider.notifier).toggle(),
                      ),
                    ),
                  if (!kReleaseMode) const _Hairline(),
                  _SettingsRow(
                    icon: Icons.visibility_off_outlined,
                    title: '隐藏开发者选项',
                    subtitle: '把这一组收起来（想再打开就重新连点版本号 8 次）',
                    onTap: () => unawaited(
                      ref.read(devOptionsUnlockedProvider.notifier).set(false),
                    ),
                    trailing: Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ShqLayout.gutter,
                ShqSpace.lg,
                ShqLayout.gutter,
                0,
              ),
              child: Text(
                '刷起 SHUAQI · 以笔为核的刷题工作台\n'
                '卷子是你的，笔迹是你的，数据只留在本机。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 分组与行 ─────────────────────────────────────────────────────────

/// 设置分组：标题 + 一张圆角卡片。分隔靠卡片内发丝线，不靠阴影。
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ShqLayout.gutter,
            ShqSpace.xl,
            ShqLayout.gutter,
            ShqSpace.sm,
          ),
          child: Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: ShqLayout.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }
}

/// 行间发丝线：缩进 64dp，正好从文字左边缘开始（图标 36 + 间距 12 + 边距 16）。
class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 64,
      endIndent: ShqLayout.gutter,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

/// 带图标的一行设置（开关 / 可点动作）。
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  /// 整行可点（AI 配置这类"进下一层"的入口）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color iconColor = scheme.onSurfaceVariant;

    final Widget row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ShqLayout.gutter,
        vertical: ShqSpace.md,
      ),
      child: Row(
        children: <Widget>[
          SoftIcon(icon: icon, size: 36, iconSize: 18, color: iconColor),
          const SizedBox(width: ShqSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: ShqSpace.sm),
            trailing!,
          ],
        ],
      ),
    );

    // 只有"进下一层"的行才包 InkWell；纯开关行由 Switch 自己处理点击，
    // 整行可点反而会误触。
    return onTap == null
        ? row
        : InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(ShqRadius.md),
            child: row,
          );
  }
}

/// 带图标与说明的**整块**设置（下面是控件，不是开关）。
class _Block extends StatelessWidget {
  const _Block({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqLayout.gutter,
        ShqSpace.md,
        ShqLayout.gutter,
        ShqSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SoftIcon(icon: icon, size: 36, iconSize: 18),
              const SizedBox(width: ShqSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: ShqSpace.md),
          child,
        ],
      ),
    );
  }
}

/// 分组内的一行说明文字。
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqLayout.gutter,
        ShqSpace.sm,
        ShqLayout.gutter,
        ShqSpace.md,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.55,
        ),
      ),
    );
  }
}

// ── 选择器 ───────────────────────────────────────────────────────────

class _Choice<T> {
  const _Choice({required this.value, required this.label, required this.icon});

  final T value;
  final String label;
  final IconData icon;
}

/// 整宽分段选择器（2–3 项）。比 Material 默认的紧凑 segmented button 更适合触屏。
class _ChoiceGroup<T> extends StatelessWidget {
  const _ChoiceGroup({
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final List<_Choice<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        for (int i = 0; i < options.length; i += 1) ...<Widget>[
          if (i > 0) const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Pressable(
              onTap: () => onSelected(options[i].value),
              scale: 0.96,
              haptic: true,
              child: AnimatedContainer(
                duration: ShqMotion.fast,
                curve: ShqMotion.curveStandard,
                padding: const EdgeInsets.symmetric(vertical: ShqSpace.md),
                decoration: BoxDecoration(
                  color: options[i].value == selected
                      ? scheme.secondaryContainer
                      : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(ShqRadius.md),
                  border: Border.all(
                    color: options[i].value == selected
                        ? scheme.primary.withValues(alpha: 0.35)
                        : scheme.outlineVariant,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      options[i].icon,
                      size: 20,
                      color: options[i].value == selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: ShqSpace.xs),
                    Text(
                      options[i].label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: options[i].value == selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurfaceVariant,
                        fontWeight: options[i].value == selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ── 色系 ─────────────────────────────────────────────────────────────

/// 色系选择：五个色点横排，点一下立刻换整套强调色。
///
/// 色点用 [ShqAccent.seed] → [ShqAccent.darkPrimary] 的**同一色相两档**
/// 做一道极浅的渐变：既是"浅色/深色都会是这个色"的暗示，也是用户要的
/// 那点"光感"（球面感），但 26dp 的尺寸下不会显得花。
class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.selected, required this.onSelected});

  final ShqAccent selected;
  final ValueChanged<ShqAccent> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Row(
      children: <Widget>[
        for (final ShqAccent accent in ShqAccent.values) ...<Widget>[
          if (accent != ShqAccent.values.first)
            const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Pressable(
              onTap: () => onSelected(accent),
              scale: 0.94,
              haptic: true,
              child: AnimatedContainer(
                duration: ShqMotion.fast,
                curve: ShqMotion.curveStandard,
                padding: const EdgeInsets.symmetric(
                  vertical: ShqSpace.sm,
                  horizontal: ShqSpace.xs,
                ),
                decoration: BoxDecoration(
                  // 未选中**不描边**：五个描边小方块叠在"主题"那三个大方块
                  // 下面会显得很碎（真机看过）。选中才浮出来，靠色点本身
                  // 传达"这里有五个色"。
                  color: accent == selected
                      ? scheme.primary.withValues(alpha: 0.09)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(ShqRadius.md),
                  border: Border.all(
                    color: accent == selected
                        ? scheme.primary.withValues(alpha: 0.32)
                        : Colors.transparent,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _dot(accent, scheme),
                    const SizedBox(height: ShqSpace.xs + 2),
                    Text(
                      accent.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: accent == selected
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontWeight: accent == selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _dot(ShqAccent accent, ColorScheme scheme) {
    final bool active = accent == selected;
    return AnimatedContainer(
      duration: ShqMotion.fast,
      curve: ShqMotion.curveStandard,
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[accent.seed, accent.darkPrimary],
        ),
        // 选中时给色点一圈同色呼吸光：这就是"选中了"的视觉语言，
        // 比加个对勾更安静（色点本身已经足够小，不再塞图标）。
        boxShadow: active
            ? ShqGlow.ring(
                accent.seed,
                alpha: 0.34,
                blur: 12,
                offset: const Offset(0, 2),
              )
            : null,
        border: Border.all(
          color: active
              ? scheme.surface
              : scheme.outlineVariant.withValues(alpha: 0.8),
          width: active ? 2 : 1,
        ),
      ),
    );
  }
}

// ── 纸感预览 ─────────────────────────────────────────────────────────

/// 纸感选择：**真实预览块** + 六个色块。
class _PaperPicker extends StatelessWidget {
  const _PaperPicker({
    required this.style,
    required this.intensity,
    required this.onStyle,
  });

  final PaperStyle style;
  final int intensity;
  final ValueChanged<PaperStyle> onStyle;

  static const List<(PaperStyle, String)> _items = <(PaperStyle, String)>[
    (PaperStyle.original, '原图'),
    (PaperStyle.warm, '暖白'),
    (PaperStyle.ivory, '象牙'),
    (PaperStyle.gray, '浅灰'),
    (PaperStyle.green, '护眼'),
    (PaperStyle.night, '夜读'),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Column(
      children: <Widget>[
        _PaperPreview(style: style, intensity: intensity),
        const SizedBox(height: ShqSpace.md),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: ShqSpace.sm,
          runSpacing: ShqSpace.sm,
          children: <Widget>[
            for (final (PaperStyle item, String label) in _items)
              SizedBox(
                width: 44,
                child: _PaperSwatch(
                  style: item,
                  label: label,
                  intensity: intensity,
                  selected: style == item,
                  onTap: () => onStyle(item),
                ),
              ),
          ],
        ),
        const SizedBox(height: ShqSpace.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '当前：${_labelOf(style)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  static String _labelOf(PaperStyle style) {
    for (final (PaperStyle item, String label) in _items) {
      if (item == style) {
        return label;
      }
    }
    return '';
  }
}

/// 一页"样子"的预览：纸色 + 一行标题 + 两行正文 + 一个 Aa。
///
/// 它不是装饰：用户在这里看到的纸色与阅读器里的乘法染纸同口径
/// （强度 100 = 白纸完全变成纸色，夜间是两端色映射）。
class _PaperPreview extends StatelessWidget {
  const _PaperPreview({required this.style, required this.intensity});

  final PaperStyle style;
  final int intensity;

  Color get _fill {
    if (style.isDarkPaper) {
      return ShqNight.paper;
    }
    final int? rgb = PaperRgb.of(style);
    if (rgb == null) {
      return ShqPaper.base;
    }
    return Color.lerp(ShqPaper.base, Color(rgb), intensity / 100)!;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = style.isDarkPaper ? ShqNight.ink : ShqPalette.ink;
    return Container(
      height: 104,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.md,
        ShqSpace.lg,
        ShqSpace.md,
      ),
      decoration: BoxDecoration(
        color: _fill,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(
          color: style.isDarkPaper ? ShqNight.pageEdge : scheme.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  '数学期中卷 · 第 1 页',
                  style: const TextStyle(
                    fontSize: ShqType.caption,
                    fontWeight: FontWeight.w600,
                    color: ShqPalette.ink,
                    height: 1.3,
                  ).copyWith(color: ink.withValues(alpha: 0.85)),
                ),
                const SizedBox(height: 5),
                Text(
                  '1. 已知函数 f(x) = x² − 2x + 3，求它在区间 [0, 3] 上的最值。',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: ink.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: ShqSpace.lg),
          Text(
            'Aa',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: ink.withValues(alpha: 0.5),
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _PaperSwatch extends StatelessWidget {
  const _PaperSwatch({
    required this.style,
    required this.label,
    required this.intensity,
    required this.selected,
    required this.onTap,
  });

  final PaperStyle style;
  final String label;
  final int intensity;
  final bool selected;
  final VoidCallback onTap;

  Color get _fill {
    if (style.isDarkPaper) {
      return ShqNight.paper;
    }
    final int? rgb = PaperRgb.of(style);
    if (rgb == null) {
      return ShqPaper.base;
    }
    return Color.lerp(ShqPaper.base, Color(rgb), intensity / 100)!;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Pressable(
      onTap: onTap,
      scale: 0.9,
      haptic: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AnimatedContainer(
            duration: ShqMotion.fast,
            curve: ShqMotion.curveStandard,
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _fill,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: selected
                ? Icon(
                    Icons.check,
                    size: 17,
                    color: style.isDarkPaper ? ShqNight.ink : scheme.primary,
                  )
                : null,
          ),
          const SizedBox(height: ShqSpace.xs),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// 默认强度。原图时置灰——没有纸色可染，滑它没有意义（真交互原则）。
class _IntensitySlider extends StatelessWidget {
  const _IntensitySlider({
    required this.style,
    required this.value,
    required this.onChanged,
  });

  final PaperStyle style;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 原图没有纸色可染；夜读是两端色映射（暗纸端 + 亮墨端），强度不参与。
    final bool enabled = style != PaperStyle.original && !style.isDarkPaper;
    return Row(
      children: <Widget>[
        Icon(
          Icons.wb_sunny_outlined,
          size: 18,
          color: enabled ? scheme.onSurfaceVariant : scheme.outlineVariant,
        ),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            max: 100,
            divisions: 20,
            label: '$value%',
            onChanged: enabled ? (double v) => onChanged(v.round()) : null,
          ),
        ),
        Container(
          width: 48,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: enabled ? scheme.surfaceContainerHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(ShqRadius.pill),
            border: Border.all(
              color: enabled ? scheme.outlineVariant : Colors.transparent,
            ),
          ),
          child: Text(
            '$value%',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(
              color: enabled ? scheme.onSurface : scheme.outline,
            ),
          ),
        ),
      ],
    );
  }
}

// ── 关于 ─────────────────────────────────────────────────────────────

String _formatTokenCount(int value) {
  if (value < 1000) {
    return '$value';
  }
  if (value < 1000000) {
    final double k = value / 1000;
    return '${k.toStringAsFixed(k >= 10 ? 0 : 1)}k';
  }
  final double m = value / 1000000;
  return '${m.toStringAsFixed(m >= 10 ? 0 : 1)}M';
}

/// 关于卡：**三栏入口**（版本说明 / 用户须知 / 用户反馈）+ 产品信息 + 版本号。
///
/// 三栏等分并排（平板上一眼看全），窄屏时自动竖排——分栏在手机上会挤成三根条。
class _AboutEntries extends StatelessWidget {
  const _AboutEntries({
    required this.onOpen,
    required this.onVersionTap,
    required this.hasUpdate,
  });

  final ValueChanged<SettingsSubPage> onOpen;
  final VoidCallback onVersionTap;
  final bool hasUpdate;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    const List<
      ({SettingsSubPage page, IconData icon, String title, String hint})
    >
    entries =
        <({SettingsSubPage page, IconData icon, String title, String hint})>[
          (
            page: SettingsSubPage.guide,
            icon: Icons.explore_outlined,
            title: '使用指南',
            hint: '从导入到导出，一页看完',
          ),
          (
            page: SettingsSubPage.releaseNotes,
            icon: Icons.new_releases_outlined,
            title: '版本说明',
            hint: '这一版能做什么',
          ),
          (
            page: SettingsSubPage.userNotice,
            icon: Icons.menu_book_outlined,
            title: '用户须知',
            hint: '权限、数据与 API 调度',
          ),
          (
            page: SettingsSubPage.feedback,
            icon: Icons.chat_bubble_outline,
            title: '用户反馈',
            hint: '问题与建议',
          ),
        ];

    return Padding(
      padding: const EdgeInsets.all(ShqLayout.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(ShqRadius.md),
                ),
                child: Text(
                  '刷',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: ShqSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(AppInfo.name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      AppInfo.tagline,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: ShqSpace.sm),
          // 2026-10-26 收尾：四个入口统一成**条形行**（用户口径），
          // 比三栏卡片更好扫、也和设置页其它行同一套语言。
          Column(
            children: <Widget>[
              for (int i = 0; i < entries.length; i += 1) ...<Widget>[
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 48,
                    color: scheme.outlineVariant,
                  ),
                _AboutRow(
                  icon: entries[i].icon,
                  title: entries[i].title,
                  hint: entries[i].hint,
                  showUpdateDot:
                      hasUpdate &&
                      entries[i].page == SettingsSubPage.releaseNotes,
                  onTap: () => onOpen(entries[i].page),
                ),
              ],
            ],
          ),
          const SizedBox(height: ShqSpace.md),
          Row(
            children: <Widget>[
              Text(
                '版本 ${AppInfo.version} · 开发中',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
              const SizedBox(width: ShqSpace.sm),
              // 版本号可连点：8 次解锁开发者选项（2026-10-26 用户第 17 条）。
              Pressable(
                onTap: onVersionTap,
                scale: 0.95,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ShqSpace.sm,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(ShqRadius.pill),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Text(
                    'v${AppInfo.version}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({
    required this.icon,
    required this.title,
    required this.hint,
    required this.onTap,
    this.showUpdateDot = false,
  });

  final IconData icon;
  final String title;
  final String hint;
  final VoidCallback onTap;
  final bool showUpdateDot;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ShqRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: ShqSpace.sm),
        child: Row(
          children: <Widget>[
            SoftIcon(icon: icon, size: 36, iconSize: 18),
            const SizedBox(width: ShqSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (showUpdateDot)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: scheme.error,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}
