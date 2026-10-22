/// 夜读 duotone 映射 —— domain 纯 Dart，只产数字不碰 Color。
///
/// 定位（2026-10-22 修正）：这是 **`PaperStyle.night` 这一种纸样式**的映射，
/// **不是"深色 App 主题的必然结果"**。App 主题管界面骨架，卷面配色由纸样式决定；
/// 深色界面 + 原图纸（白底黑字）是正常组合。
///
/// 设计动机（T1.6 的"暗色遮罩"按用户要求升级为"暗色质感"）：
/// 0.18 纯黑罩只是"把纸调暗"，黑字留在暗纸上，对比度从 21:1 掉到 ~5:1，
/// 长时间读小字吃力。duotone 把亮度轴翻转，同时保住暖色基因：
///
/// ```text
/// 白纸 → 暖黑纸 #191612      黑字 → 暖白墨 #E9E3D5
/// ```
///
/// 对比度回到 ~13:1；暖黑纸 / 暖白墨是浅色模式"纸感暖色 / 墨色"的镜像延续。
/// 代价：彩色内容（红印章、彩色插图）退化为双色暖调——夜读模式下可接受，
/// 像旧照片，也符合"低干扰、不抢题面"。
///
/// 映射走 `ColorFilter.matrix`（一次 GPU pass，与浅色纸感的乘法滤镜同量级），
/// 只作用背景层；笔迹层是兄弟节点，永不吃这个滤镜（REQ-15 红线）。
library;

/// 夜读两端色值（`0xAARRGGBB` 纯 int，与 [PaperRgb] 同一约定：
/// domain 不许碰 Flutter 的 `Color`）。
abstract final class NightRgb {
  /// 夜读纸色：白纸映射到它。
  static const int paper = 0xFF191612;

  /// 夜读墨色：黑字映射到它。
  static const int ink = 0xFFE9E3D5;
}

/// 灰度 → duotone 的映射，以及现成的 `ColorFilter.matrix` 参数。
///
/// 公式（输入输出都归一化到 0..1）：
/// ```text
/// y     = 0.2126·r + 0.7152·g + 0.0722·b      // Rec.709 亮度
/// out_c = ic + (pc - ic) · y                  // 黑端 ink，白端 paper
/// ```
abstract final class NightTint {
  /// Rec.709 亮度权重（对 sRGB 的近似，忽略 gamma，视觉足够）。
  static const List<double> luma = <double>[0.2126, 0.7152, 0.0722];

  static final double _paperR = _channel(NightRgb.paper, 16);
  static final double _paperG = _channel(NightRgb.paper, 8);
  static final double _paperB = _channel(NightRgb.paper, 0);
  static final double _inkR = _channel(NightRgb.ink, 16);
  static final double _inkG = _channel(NightRgb.ink, 8);
  static final double _inkB = _channel(NightRgb.ink, 0);

  /// `ColorFilter.matrix` 的 20 个参数（行优先：RGB 行 + 偏移列，alpha 恒等）。
  ///
  /// ## 单位陷阱（2026-10-22 真机"整页死黑"事故的根因，不许再犯）
  /// `ColorFilter.matrix` 的**输入通道与第 5 列偏移都是 0..255 的字节值**，
  /// 不是 0..1 的归一化值：
  /// ```text
  /// out_255 = m0·R255 + m1·G255 + m2·B255 + m4
  /// ```
  /// 系数是无量纲的（`dr·luma` 直接可用），但**偏移必须 ×255**。
  /// 之前把归一化的 ink（≈0.91）当偏移填进去，白纸算出来是
  /// `-0.816×255 + 0.91 ≈ -207` → 钳到 0 → 整页纯黑，黑字也被压成 0，
  /// 于是"暗色下所有 PDF 都是一片死黑"。
  static final List<double> matrix = _buildMatrix();

  /// 对单个归一化 RGB 应用映射（文档 / 逻辑单测用；GPU 走 [matrix]）。
  static (double, double, double) apply(double r, double g, double b) {
    final double y = luma[0] * r + luma[1] * g + luma[2] * b;
    return (
      _inkR + (_paperR - _inkR) * y,
      _inkG + (_paperG - _inkG) * y,
      _inkB + (_paperB - _inkB) * y,
    );
  }

  /// 把 [matrix] 作用到 **0..255** 的通道值上——与 GPU 的算法逐位一致。
  ///
  /// 单测必须走这条（而不是归一化的 [apply]），否则又会漏掉"偏移没乘 255"这类
  /// 只在真机上才现形的事故。
  static (double, double, double) applyByte(double r, double g, double b) {
    final List<double> m = matrix;
    return (
      m[0] * r + m[1] * g + m[2] * b + m[4],
      m[5] * r + m[6] * g + m[7] * b + m[9],
      m[10] * r + m[11] * g + m[12] * b + m[14],
    );
  }

  static double _channel(int argb, int shift) =>
      ((argb >> shift) & 0xFF) / 255.0;

  static List<double> _buildMatrix() {
    final double dr = _paperR - _inkR;
    final double dg = _paperG - _inkG;
    final double db = _paperB - _inkB;
    return <double>[
      dr * luma[0], dr * luma[1], dr * luma[2], 0, _inkR * 255, //
      dg * luma[0], dg * luma[1], dg * luma[2], 0, _inkG * 255, //
      db * luma[0], db * luma[1], db * luma[2], 0, _inkB * 255, //
      0, 0, 0, 1, 0,
    ];
  }
}
