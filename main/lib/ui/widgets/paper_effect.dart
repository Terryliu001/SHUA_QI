import 'package:flutter/material.dart';
import 'package:shuaqi/domain/reader/night_tint.dart';
import 'package:shuaqi/domain/reader/paper_tint.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 纸感效果：只作用在**背景层**上，绝不碰前景（笔迹层是它的兄弟节点，不是子节点）。
///
/// 三种视觉态（§6.9.3 + T1.6 暗色升级）：
/// - `original` / 浅色：零处理，直接透传（可信基线）；
/// - 其它样式 / 浅色：`ColorFilter.matrix` 做**乘法**染纸（白→纸色、黑→黑，文字不灰），
///   再叠一层 ≤3% 的噪点纹理；
/// - 深色：纸感让位给**夜读 duotone**（[NightTint]）——白纸→暖黑纸、黑字→暖白墨。
///
/// 为什么深色从"0.18 黑罩"升级为 duotone：黑罩只是把纸调暗，黑字留在暗纸上，
/// 对比度从 21:1 掉到 ~5:1；duotone 翻转亮度轴，对比度回到 ~13:1，
/// 且暖黑纸 / 暖白墨正是浅色模式"纸感暖色 / 墨色"的镜像。彩色内容退化为
/// 双色暖调（像旧照片）——夜读可接受，见项目日志 017。
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

    if (isDark) {
      // 夜读：不论存的什么纸感偏好，一律 duotone（偏好仍在，切回浅色即恢复）。
      return ColorFiltered(
        colorFilter: ColorFilter.matrix(NightTint.matrix),
        child: child,
      );
    }

    // 浅色：乘法染纸（纸感），original 零处理
    final PaperTint tint = PaperTint.forStyle(style, intensity);
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
    if (style != PaperStyle.original) {
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
    return result;
  }
}
