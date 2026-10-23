import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';

/// 缩略图抽屉：竖向网格 + 点一下跳页。
///
/// 用 `GridView.builder` 懒构建：300 页的卷只会渲染当前可见的十来张小图，
/// 不会在打开抽屉的瞬间把 300 页全渲染一遍（那会直接卡死）。
///
/// 2026-10-23 设计收尾：当前页用**主色描边 + 页码胶囊**标出来，
/// 顶栏给出总数与关闭入口；每张缩略图右下角都有页码（不再靠数格子）。
class ThumbDrawer extends StatelessWidget {
  const ThumbDrawer({
    super.key,
    required this.pages,
    required this.cache,
    required this.currentPage,
    required this.onSelected,
  });

  final List<WbPage> pages;
  final PageImageCache cache;
  final int currentPage;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final WbPage first = pages.first;
    final double aspect = first.width <= 0
        ? 0.75
        : first.width / first.height;

    return Drawer(
      width: 344,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
          left: Radius.circular(ShqRadius.xl),
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ShqSpace.lg,
                ShqSpace.md,
                ShqSpace.sm,
                ShqSpace.sm,
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.grid_view_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: ShqSpace.sm),
                  Text('页面', style: theme.textTheme.titleMedium),
                  const SizedBox(width: ShqSpace.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: ShqSpace.sm,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(ShqRadius.pill),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Text(
                      '共 ${pages.length} 页',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(ShqSpace.md),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: ShqSpace.md,
                  crossAxisSpacing: ShqSpace.md,
                  childAspectRatio: aspect,
                ),
                itemCount: pages.length,
                itemBuilder: (BuildContext context, int index) {
                  final bool active = index == currentPage;
                  return Pressable(
                    onTap: () {
                      onSelected(index);
                      Navigator.of(context).pop();
                    },
                    scale: 0.96,
                    haptic: true,
                    child: AnimatedContainer(
                      duration: ShqMotion.fast,
                      curve: ShqMotion.curveStandard,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(ShqRadius.md),
                        border: Border.all(
                          color: active
                              ? scheme.primary
                              : scheme.outlineVariant,
                          width: active ? 2 : 1,
                        ),
                      ),
                      padding: const EdgeInsets.all(3),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(ShqRadius.sm),
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            PageLayer(
                              cache: cache,
                              page: pages[index],
                              width: 130,
                            ),
                            // 页码胶囊：一眼知道这是第几页。
                            Positioned(
                              right: 5,
                              bottom: 5,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: active
                                      ? scheme.primary
                                      : scheme.surfaceContainerHighest
                                            .withValues(alpha: 0.9),
                                  borderRadius: BorderRadius.circular(
                                    ShqRadius.pill,
                                  ),
                                ),
                                child: Text(
                                  '${index + 1}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: active
                                        ? scheme.onPrimary
                                        : scheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
