import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/ui/panel/question_thumb.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 右侧面板里的**题面预览**（只画选中的那道题）。
///
/// 为什么需要它：PDF 文本层给的公式是"按字形排的碎片"，`𝑓(𝑥)`、大括号、
/// 无穷号经常没有 Unicode 码位（私有区 PUA），纯文本预览只能做到"可读的近似"。
/// 要**原样**看到公式，最省事、最可靠的办法是把 PDF 那一块裁出来画。
///
/// 2026-10-24 改版（用户第 2 条）：
/// - **不再在框内做 2× 缩放**：那个交互让"点一下"承担了两件事（放大/缩小），
///   而且放大后只能看局部、退不出去。现在点击 = 打开独立弹窗看大图；
/// - **不再纵向裁切**：以前按 `maxHeight` 截断，长题被裁掉下半截、
///   极宽的题上下不居中，看起来"比例不对"。现在整题按真实比例缩进框里（contain），
///   要细节就点开弹窗。
class RegionPreview extends StatelessWidget {
  const RegionPreview({
    super.key,
    required this.cache,
    required this.page,
    required this.rect,
    required this.width,
    this.maxHeight = 160,
    this.note,
    this.showTitle = true,
    this.onTap,
    this.onLongPress,
  });

  final PageImageCache cache;
  final WbPage page;

  /// 题目在页面坐标（pt）里的区域。
  final RegionRect rect;

  /// 面板里的显示宽度（逻辑 px）。
  final double width;

  /// 最高显示高度；整题按比例缩进这个框里，**不再裁切**。
  final double maxHeight;

  /// 可选的说明（例如"公式题以卷面为准，不做文字转写"）。
  final String? note;

  /// 是否显示顶部的「题面预览」标题。
  ///
  /// 答题卡栅格里每张卡片已经有题号，再重复一行标题只会挤占题面高度。
  final bool showTitle;

  /// 点击预览 → 打开独立大图弹窗（父层负责，因为要带保存动作）。
  final VoidCallback? onTap;

  /// 长按预览 → 图片侧边浮窗（保存等动作）。
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double aspect = rect.width / math.max(1, rect.height);
    final double naturalHeight = width / math.max(0.05, aspect);
    // 框高：不超过 maxHeight，也不低于 56（太扁的题也要留一条可点的区域）。
    final double height = math.min(maxHeight, math.max(56, naturalHeight));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showTitle)
          Row(
            children: <Widget>[
              Text(
                '题面预览',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: ShqType.caption,
                ),
              ),
              if (onTap != null) ...<Widget>[
                const Spacer(),
                Icon(Icons.zoom_in, size: 13, color: scheme.outline),
              ],
            ],
          ),
        if (showTitle && note != null && note!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 1),
          Text(
            note!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.outline,
              fontSize: ShqType.caption - 0.5,
            ),
          ),
        ],
        if (showTitle) const SizedBox(height: ShqSpace.xxs),
        Tooltip(
          message: onTap == null ? '' : '点开看大图，长按保存图片',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            onLongPress: onLongPress,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ShqRadius.sm),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: ShqPaper.base,
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(ShqRadius.sm),
                ),
                child: SizedBox(
                  width: width,
                  height: height,
                  child: QuestionThumb(
                    cache: cache,
                    page: page,
                    rect: rect,
                    width: width,
                    height: height,
                    paperColor: ShqPaper.base,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
