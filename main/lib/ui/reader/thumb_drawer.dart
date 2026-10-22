import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 缩略图抽屉：竖向列表 + 点一下跳页。
///
/// 用 `GridView.builder` 懒构建：300 页的卷只会渲染当前可见的十来张小图，
/// 不会在打开抽屉的瞬间把 300 页全渲染一遍（那会直接卡死）。
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
    final WbPage first = pages.first;
    final double aspect = first.width <= 0
        ? 0.75
        : first.width / first.height;

    return Drawer(
      width: 320,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ShqSpace.lg,
                ShqSpace.lg,
                ShqSpace.lg,
                ShqSpace.sm,
              ),
              child: Text(
                '共 ${pages.length} 页',
                style: theme.textTheme.titleMedium,
              ),
            ),
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
                  return GestureDetector(
                    onTap: () {
                      onSelected(index);
                      Navigator.of(context).pop();
                    },
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        // 未选中不描边（border: null），而不是画一根透明边
                        border: active
                            ? Border.all(
                                color: theme.colorScheme.primary,
                                width: 2,
                              )
                            : null,
                        borderRadius: BorderRadius.circular(ShqRadius.sm),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: PageLayer(
                          cache: cache,
                          page: pages[index],
                          width: 130,
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
