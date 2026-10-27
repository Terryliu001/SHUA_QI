import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shuaqi/app/records/profile_store.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';

/// 记录页页首的「个人空间」。
///
/// 结构（自上而下）：
/// - 底层：自定义封面图，或跟随主题底色（用户的"默认"）；
/// - 右下角压一行：圆形头像 + 昵称 + 格言；
/// - 右上角：⋯（换头像 / 换封面 / 改昵称格言 / 恢复默认）。
///
/// 两个细节值得说明：
/// 1. **封面用 `cacheWidth` 解码**：12MP 照片原尺寸解码要 ~48MB，
///    页首只要屏宽像素（上限 1600），解码时直接降采样，内存压到 ~1/10；
/// 2. **有封面就压一层由下往上的暗渐变**：否则浅色封面上的白字读不出来。
///    没有封面时不压，文字用主题色（浅色主题深字、暗色主题浅字）。
class RecordsProfileHeader extends StatelessWidget {
  const RecordsProfileHeader({
    super.key,
    required this.profile,
    required this.avatarFile,
    required this.coverFile,
    required this.onMenu,
    required this.onEditText,
    required this.onAvatarTap,
    this.imageEpoch = 0,
  });

  final ProfileData profile;
  final File avatarFile;
  final File coverFile;
  final VoidCallback onMenu;
  final VoidCallback onEditText;

  /// 头像/封面文件路径不变，ImageCache 清掉后 Image widget 仍可能复用旧
  /// ImageStream；用 epoch 换 Key，强制重新解码（2026-10-26 用户：裁完不立刻生效）。
  final int imageEpoch;

  /// 点头像 = 换头像（2026-10-25 用户第 2 条：要有提示、要能换）。
  final VoidCallback onAvatarTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool hasCover = profile.hasCover;
    final Color onCover = hasCover ? Colors.white : scheme.onSurface;
    final Color onCoverMuted = hasCover
        ? Colors.white.withValues(alpha: 0.78)
        : scheme.onSurfaceVariant;

    // 2026-10-25 用户："图片展示区加大一点，一点就好"——涨 18dp：
    // 有封面时更像一张"封面"，没有封面时头像与格言也不至于挤在一条细带上。
    return SizedBox(
      height: hasCover ? 230 : 196,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _background(context, theme, hasCover),
          if (hasCover)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  // 顶部压一点（让 ⋯ 按钮在亮封面上也看得清），底部压深
                  // （昵称/格言压在图上，必须保证对比度）。
                  colors: <Color>[
                    Color(0x33000000),
                    Color(0x00000000),
                    Color(0xCC000000),
                  ],
                  stops: <double>[0, 0.34, 1],
                ),
              ),
            ),
          Positioned(
            left: ShqSpace.xl,
            right: ShqSpace.md,
            bottom: ShqSpace.lg,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                GestureDetector(
                  onTap: onAvatarTap,
                  child: Tooltip(
                    message: profile.hasAvatar ? '更换头像' : '设置头像',
                    child: _avatar(theme),
                  ),
                ),
                const SizedBox(width: ShqSpace.lg),
                Expanded(
                  child: Pressable(
                    onTap: onEditText,
                    scale: 0.995,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (profile.name.isNotEmpty)
                          Text(
                            profile.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: onCover,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (profile.name.isNotEmpty)
                          const SizedBox(height: ShqSpace.xxs),
                        Text(
                          profile.motto.isEmpty ? '点这里写一句给自己的话' : profile.motto,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: profile.motto.isEmpty
                                ? onCoverMuted.withValues(alpha: 0.7)
                                : onCoverMuted,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: ShqSpace.sm),
              ],
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(
                  top: ShqSpace.xs,
                  right: ShqSpace.xs,
                ),
                child: IconButton(
                  tooltip: '个人空间设置',
                  onPressed: onMenu,
                  icon: Icon(Icons.more_horiz, color: onCover),
                  style: IconButton.styleFrom(
                    backgroundColor: hasCover
                        ? Colors.black.withValues(alpha: 0.22)
                        : scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _background(BuildContext context, ThemeData theme, bool hasCover) {
    if (!hasCover) {
      // 默认底色"跟随系统"：用主题表面色，避免大片纯色显得空。
      return DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
      );
    }
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final double width = MediaQuery.sizeOf(context).width;
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Image.file(
        coverFile,
        key: ValueKey<String>('cover-$imageEpoch'),
        fit: BoxFit.cover,
        // 只解码到屏幕像素宽（上限 1600），不做重编码。
        cacheWidth: (width * dpr).clamp(320, 1600).round(),
        errorBuilder: (
          BuildContext context,
          Object error,
          StackTrace? stackTrace,
        ) => const SizedBox.shrink(),
      ),
    );
  }

  Widget _avatar(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    // 2026-10-27 用户：「头像框里还能看到矩形的裁切边，图没占满圆框」。
    //
    // 根因：`BoxDecoration` 的 `border` 会变成 Container 的**内边距**
    // （`decoration.padding` = 2.5），图片被缩成 73×73，而 ClipPath 仍是
    // 78 的整圆 → 圆的上下左右四个顶点落在图片外，图片的**直边**露在圆里，
    // 看起来就是「圆框里有个带圆角的方框」。
    //
    // 修法：**边框改画在图片上层**（`foregroundDecoration` 不参与布局、
    // 也不产生内边距），图片按 78×78 铺满再被圆裁掉，圆框内 100% 是图。
    // 边框颜色/宽度保持不变，视觉上只是从「挤小图」变成「压在图上的环」。
    return Container(
      width: 78,
      height: 78,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surfaceContainerHighest,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      foregroundDecoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: profile.hasCover
              ? Colors.white.withValues(alpha: 0.9)
              : scheme.surface,
          width: 2.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: profile.hasAvatar
          ? Image.file(
              avatarFile,
              key: ValueKey<String>('avatar-$imageEpoch'),
              width: 78,
              height: 78,
              fit: BoxFit.cover,
              cacheWidth: 320,
              errorBuilder: (
                BuildContext context,
                Object error,
                StackTrace? stackTrace,
              ) => _avatarFallback(theme),
            )
          : _avatarFallback(theme),
    );
  }

  Widget _avatarFallback(ThemeData theme) {
    final String name = profile.name.trim();
    return Center(
      child: name.isEmpty
          ? Icon(
              Icons.person_outline,
              size: 34,
              color: theme.colorScheme.onSurfaceVariant,
            )
          : Text(
              name.characters.first,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
    );
  }
}
