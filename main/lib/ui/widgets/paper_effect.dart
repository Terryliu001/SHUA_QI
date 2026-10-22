import 'package:flutter/material.dart';
import 'package:shuaqi/domain/reader/night_tint.dart';
import 'package:shuaqi/domain/reader/paper_tint.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 纸感效果：只作用在**背景层**上，绝不碰前景（笔迹层是它的兄弟节点，不是子节点）。
///
/// ## 三种视觉态，由 [style] 决定 —— **与 App 主题无关**
/// - `original`：零处理（白底黑字，可信基线）；
/// - `warm / ivory / gray / green`：`ColorFilter.matrix` 做**乘法**染纸
///   （白→纸色、黑→黑，文字不灰），再叠一层 ≤3% 的噪点纹理；
/// - `night`：**duotone 反色**（[NightTint]）——白纸→暖黑纸、黑字→暖白墨，
///   不叠噪点。
///
/// 为什么不再看 `Theme.brightness`（2026-10-22 用户拍板改的）：
/// 原来的规则是"App 一进深色，所有卷面强制夜读"。但深色主题说的是**界面**，
/// 不是卷子：用户要的是"黑底白字作为一种可选风格"，同时也必须能在深色界面下
/// 正常看白底黑字的卷子（老师在暗光里批卷、投影仪场景、彩色插图都会因此失真）。
/// 于是配色选择权完全交还给 [PaperStyle]，主题只管骨架明暗。
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
    // 夜读：duotone 反色。强度无关（映射是"黑端/白端"两端色，不是叠色比例）。
    if (style.isDarkPaper) {
      return ColorFiltered(
        colorFilter: ColorFilter.matrix(NightTint.matrix),
        child: child,
      );
    }

    // 其余：乘法染纸（original 零处理）
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
