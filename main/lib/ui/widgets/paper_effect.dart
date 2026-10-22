import 'package:flutter/material.dart';
import 'package:shuaqi/domain/reader/paper_tint.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 纸感效果：只作用在**背景层**上，绝不碰前景（笔迹层是它的兄弟节点，不是子节点）。
///
/// 三种视觉态（§6.9.3）：
/// - `original` / 浅色：零处理，直接透传（可信基线）；
/// - 其它样式 / 浅色：`ColorFilter.matrix` 做**乘法**染纸（白→纸色、黑→黑，文字不灰），
///   再叠一层 ≤3% 的噪点纹理；
/// - 深色：强制 original，叠一层暗色遮罩（[ShqPaper.darkScrimAlpha]）压住刺眼白。
///
/// 为什么不做成"每次重新渲染位图"：屏显是 GPU 贴图，滤镜与噪点都是 GPU 合成的
/// 一次 pass，没有 CPU 逐像素计算，也没有 PNG 编码（T0.4 实测 PNG 编码占 120ms）。
/// 这样切换样式天然 ≤1 帧，无需缓存，也不存在"切样式要重新渲染一页"的卡顿。
class PaperEffect extends StatelessWidget {
  const PaperEffect({
    super.key,
    required this.style,
    required this.intensity,
    required this.child,
  });

  final PaperStyle style;
  final int intensity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    // 深色模式：纸感让位给暗色遮罩（§6.9.3，与 ReaderPrefs.forSurfaceBrightness 同规则）
    final PaperStyle effective = isDark ? PaperStyle.original : style;
    final PaperTint tint = PaperTint.forStyle(effective, intensity);

    Widget result = child;
    if (!tint.isIdentity) {
      result = ColorFiltered(
        colorFilter: ColorFilter.matrix(<double>[
          tint.r, 0, 0, 0, 0, //
          0, tint.g, 0, 0, 0, //
          0, 0, tint.b, 0, 0, //
          0, 0, 0, 1, 0,
        ]),
        child: result,
      );
    }
    if (!isDark && effective != PaperStyle.original) {
      result = Stack(
        children: <Widget>[
          result,
          const Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: ShqPaper.noiseOpacity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: AssetImage('assets/textures/paper_noise.png'),
                      repeat: ImageRepeat.repeat,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (isDark) {
      result = Stack(
        children: <Widget>[
          result,
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: ShqPaper.darkScrimAlpha),
              ),
            ),
          ),
        ],
      );
    }
    return result;
  }
}
