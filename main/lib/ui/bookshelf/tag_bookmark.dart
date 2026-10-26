import 'package:flutter/material.dart';

import 'package:shuaqi/ui/theme/hex_color.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

// ── 标签书签（2026-10-24 用户第 7 条；10-24 收尾按圆角口径重做）──────

/// 书签自己的圆角（dp）。
///
/// 卡片圆角是 [ShqRadius.lg]（20）。书签不给同样的量级：它是"贴在卡片上的
/// 小色块"，跟卡片同圆角会显得钝；但也不能是直角——原版直角压在 20 圆角的
/// 卡片角上，尖角戳出卡片轮廓，这就是"圆角没处理好"的来源。
const double kBookmarkRadius = 6;

/// 竖排书签的宽度（dp）。大图卡上它是一条窄色带，再宽就跟缩略图抢地方了。
const double kBookmarkVerticalWidth = 21;

/// 竖排最多几个字。标签上限是 12 字，全竖排会比卡片还高。
const int kBookmarkVerticalLines = 4;

/// 卡片右上角的一组标签书签。
///
/// 用 `Positioned` 挂在卡片外的 Stack 上：**不占布局**——有没有标签，
/// 卡片尺寸、圆角、缩略图位置完全一样（用户明确要求不能因标签改变卡面）。
class TagBookmarks extends StatelessWidget {
  const TagBookmarks({
    super.key,
    required this.tags,
    required this.colorOf,
    this.max = 3,
    this.vertical = false,
    this.onLongPress,
  });

  final List<String> tags;
  final Color Function(String tag) colorOf;

  /// 最多画几个：卡片宽度有限，3 个以上就叠成一条彩带了。
  final int max;

  /// true = 文字竖排（大图卡：书签做窄，避开卡片右上角的大圆角）。
  final bool vertical;
  final ValueChanged<String>? onLongPress;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final String tag in tags.take(max))
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: TagBookmark(
              tag: tag,
              color: colorOf(tag),
              vertical: vertical,
              onLongPress: onLongPress == null ? null : () => onLongPress!(tag),
            ),
          ),
      ],
    );
  }
}

/// 一枚书签：色块 + 标签名 + 底部的 V 形缺口（书签尾）。
///
/// 两个形态：
/// - [vertical] = false（列表卡）：文字横向，最宽 74dp；
/// - [vertical] = true（大图卡）：文字竖向、书签收窄到 [kBookmarkVerticalWidth]，
///   既避开卡片 20dp 的大圆角，也不压住缩略图的主视线。
class TagBookmark extends StatelessWidget {
  const TagBookmark({
    super.key,
    required this.tag,
    required this.color,
    this.vertical = false,
    this.onLongPress,
  });

  final String tag;
  final Color color;
  final bool vertical;
  final VoidCallback? onLongPress;

  /// 竖排：一个字一行。用 runes 拆而不是 `split('')`——后者遇到 emoji /
  /// 代理对会把字符劈成两半。
  static String verticalText(String tag) =>
      <String>[for (final int rune in tag.runes) String.fromCharCode(rune)]
          .join('\n');

  @override
  Widget build(BuildContext context) {
    final bool dark =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
    final Color fg = dark ? Colors.white : const Color(0xFF1B1B1B);
    final TextStyle style = TextStyle(
      fontSize: vertical ? 10 : 10.5,
      height: 1.15,
      fontWeight: FontWeight.w600,
      color: fg,
    );
    final Widget text = vertical
        ? SizedBox(
            width: kBookmarkVerticalWidth,
            child: Text(
              verticalText(tag),
              maxLines: kBookmarkVerticalLines,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: style,
            ),
          )
        : Text(
            tag,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
    return Semantics(
      label: '标签 $tag',
      child: ClipPath(
        clipper: const BookmarkClipper(),
        child: GestureDetector(
          onLongPress: onLongPress,
          child: Container(
            constraints: vertical
                ? const BoxConstraints()
                : const BoxConstraints(maxWidth: 74),
            padding: vertical
                ? const EdgeInsets.fromLTRB(0, 5, 0, 8)
                : const EdgeInsets.fromLTRB(7, 4, 7, 8),
            color: color,
            child: text,
          ),
        ),
      ),
    );
  }
}

/// 书签形状：**顶部两角带圆角** + 底部居中的 V 形缺口。
///
/// 顶部给圆角就是这次的关键修正：书签整体往卡片内侧挪了 [ShqSpace.xs]，
/// 但直角的两枚尖角仍会戳出卡片 20dp 圆角的弧线之外。
class BookmarkClipper extends CustomClipper<Path> {
  const BookmarkClipper();

  /// 缺口深度（dp）。
  static const double notch = 5;

  @override
  Path getClip(Size size) {
    final double r = kBookmarkRadius < size.width / 2
        ? kBookmarkRadius
        : size.width / 2;
    final double depth = notch < size.height / 2 ? notch : size.height / 2;
    return Path()
      // 二次贝塞尔而不是 arcToPoint：后者要算 sweep 方向，写错了会凹成反角。
      // 控制点落在角上，小半径下与正圆弧肉眼无差。
      ..moveTo(0, r)
      ..quadraticBezierTo(0, 0, r, 0)
      ..lineTo(size.width - r, 0)
      ..quadraticBezierTo(size.width, 0, size.width, r)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width / 2, size.height - depth)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant BookmarkClipper oldClipper) => false;
}

/// 一个色点（标签配色 / 文件夹配色共用）。
class SwatchDot extends StatelessWidget {
  const SwatchDot({
    super.key,
    required this.hex,
    required this.selected,
    required this.onTap,
    this.label,
  });

  final String hex;
  final bool selected;
  final VoidCallback onTap;

  /// 语义标签（读屏 / 提示用）。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = shqHexColor(hex);
    return Tooltip(
      message: label ?? '',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ShqRadius.pill),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : Colors.transparent,
              width: 2,
            ),
          ),
          child: selected
              ? Icon(
                  Icons.check,
                  size: 16,
                  color: ThemeData.estimateBrightnessForColor(color) ==
                          Brightness.dark
                      ? Colors.white
                      : const Color(0xFF1B1B1B),
                )
              : null,
        ),
      ),
    );
  }
}
