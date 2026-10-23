import 'package:flutter/material.dart';

/// 软底图标：一个线性图标落在圆角/圆形浅色块里。
///
/// 2026-10-23 设计收尾抽出来的公共件。设置行、功能预览、空态都用它，
/// 保证"图标底"永远是同一档表面色 + 同一根发丝边，而不是每页各调一次。
class SoftIcon extends StatelessWidget {
  const SoftIcon({
    super.key,
    required this.icon,
    this.size = 40,
    this.iconSize = 20,
    this.color,
    this.background,
    this.circle = false,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? background;

  /// true = 圆形（空态/预览页用），false = 软圆角（设置行用）。
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? scheme.surfaceContainerHigh,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(size * 0.3),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Icon(
        icon,
        size: iconSize,
        color: color ?? scheme.onSurfaceVariant,
      ),
    );
  }
}
