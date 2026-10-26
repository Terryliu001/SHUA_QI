import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/question_kind.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/ui/panel/grade_dot.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';

/// 题型 → 中文短标签（收藏夹卡片与列表共用）。
///
/// 实现已挪到 `domain/model/question_kind.dart`（记录页也要同一份文案），
/// 这里保留旧名字，避免把 6 个调用点全部改一遍。
String favoriteKindLabel(String kind) => questionKindLabel(kind);

/// 收藏夹卡片（网格卡，对齐书架大图卡风格）。
///
/// 结构：题面缩略图（`stem.png`，`BoxFit.cover` 压进固定区域，切得再歪也整齐）+
/// 右上角判定徽标 + 题号/题型 + 知识点标签 + 卷名。
///
/// 迁移来的老收藏没有 `stem.png`：`errorBuilder` 兜底显示题号占位，绝不空白。
class FavoriteCard extends ConsumerWidget {
  const FavoriteCard({
    super.key,
    required this.favorite,
    required this.onTap,
    required this.onLongPress,
    this.selected,
  });

  final Favorite favorite;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// 多选态：null = 不可选（普通浏览）；true/false = 可选且当前是否选中。
  ///
  /// 选中圈画在题面图**右上角**：这是唯一不压题号/卷名/判定点的空位，
  /// 而且只在多选时出现（056 把判定点移到元信息区就是为了平时不遮题面）。
  final bool? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final File stem = ref
        .watch(vaultProvider)
        .file(VaultPaths.favoriteStem(favorite.id));
    final bool? picked = selected;

    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: 0.985,
      child: Card(
        clipBehavior: Clip.antiAlias,
        // 选中光晕（2026-10-26）：与书架卡同一套（`ShqGlow.selectedAlpha`）。
        // 这里已经有主色描边，再加一圈同色光，"已选中"在暗色卡片墙上一眼可见。
        elevation: picked == true ? 6 : 0,
        shadowColor: picked == true
            ? scheme.primary.withValues(alpha: ShqGlow.selectedAlpha)
            : null,
        shape: picked == true
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ShqRadius.lg),
                side: BorderSide(color: scheme.primary, width: 1.6),
              )
            : null,
        child: Stack(
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 题面图按固定 3:2 比例呈现（比之前 Expanded 填满矮约 1/3），
                // 元信息区占更大视觉比重。
                AspectRatio(
                  aspectRatio: 3 / 2,
                  child: _StemImage(file: stem, label: favorite.label),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    ShqSpace.md,
                    ShqSpace.sm,
                    ShqSpace.md,
                    ShqSpace.md,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            // 题号 + 题型同一行，避免有/没有标签时卡片高度不一致。
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    '第 ${favorite.label} 题',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: ShqSpace.xs),
                                Text(
                                  favoriteKindLabel(favorite.kind),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: ShqSpace.xs),
                            // 知识点标签（最多 2 枚）。
                            if (favorite.knowledgeTags.isNotEmpty)
                              Wrap(
                                spacing: ShqSpace.xs,
                                runSpacing: ShqSpace.xxs,
                                children: <Widget>[
                                  for (final String tag
                                      in favorite.knowledgeTags.take(2))
                                    _KnowledgePill(label: tag),
                                ],
                              )
                            else
                              Text(
                                '未归纳',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.outline,
                                ),
                              ),
                            const SizedBox(height: ShqSpace.xs),
                            // 卷名 + 后置的「原卷已删」：不抢眼，但长卷名省略时
                            // 仍保证状态可见（名字收缩、后缀不缩）。
                            Row(
                              children: <Widget>[
                                Flexible(
                                  child: Text(
                                    favorite.workbookTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                if (favorite.sourceDeleted)
                                  Text(
                                    ' · 原卷已删',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.outline,
                                      fontSize: 10.5,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: ShqSpace.sm),
                      // 判定圆点：放在元信息区右下角，不遮题面。
                      Padding(
                        padding: const EdgeInsets.only(bottom: 1),
                        child: GradeDot(verdict: favorite.verdict, size: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (picked != null)
              Positioned(
                top: ShqSpace.xs,
                right: ShqSpace.xs,
                child: _SelectBadge(selected: picked),
              ),
          ],
        ),
      ),
    );
  }
}

/// 多选勾选圈：半透明白底 + 主色勾（与书架多选的视觉语言一致）。
class _SelectBadge extends StatelessWidget {
  const _SelectBadge({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: ShqMotion.instant,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: selected ? scheme.primary : Colors.white.withValues(alpha: 0.86),
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: 1.4,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 4,
          ),
        ],
      ),
      child: Icon(
        Icons.check,
        size: 16,
        color: selected ? scheme.onPrimary : Colors.transparent,
      ),
    );
  }
}

/// 题面缩略图 + 缺图兜底。
class _StemImage extends StatelessWidget {
  const _StemImage({required this.file, required this.label});

  final File file;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 题面图按原比例完整呈现（contain），居中；比例不对时上下/左右用纸色填充。
    return ColoredBox(
      color: ShqPaper.base,
      child: Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stackTrace) {
          // 迁移来的老收藏没有题面图：显示题号占位，不空白、不误导。
          return ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Center(
              child: Text(
                '第 $label 题',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 知识点标签小胶囊。
class _KnowledgePill extends StatelessWidget {
  const _KnowledgePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(ShqRadius.pill),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSecondaryContainer,
          fontSize: 10.5,
        ),
      ),
    );
  }
}
