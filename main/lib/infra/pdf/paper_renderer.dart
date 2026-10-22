import 'dart:typed_data';

import 'package:shuaqi/domain/reader/reader_prefs.dart';

/// 背景渲染契约（规格 §7）。
///
/// 两个方法必须由同一个实现提供，且**必须共用同一份页面位图缓存**——
/// 否则导出时会为了"原图"再渲染一遍整页，20 页 PDF 会白烧一倍时间（REQ-12 的预算）。
abstract interface class PaperRenderer {
  /// 返回**已应用纸样式**的页位图（PNG）。
  ///
  /// 实现方硬性要求：
  /// 1. 按 `(pageIndex, style, intensity)` 三元组缓存，滑动时不得每帧重算（§5.6：单页 ≤8ms）。
  /// 2. 滤镜只作用背景层，绝不把笔迹一起滤镜。
  /// 3. `prefs.style == original` 时必须走零处理路径，不许绕一圈 ColorFilter 再出来。
  Future<Uint8List> renderStyled(
    int pageIndex, {
    required double scale,
    required ReaderPrefs prefs,
  });

  /// 导出专用：永远是原图，绕过滤镜（§6.9.3）。
  Future<Uint8List> renderOriginal(int pageIndex, {required double maxEdgePx});
}
