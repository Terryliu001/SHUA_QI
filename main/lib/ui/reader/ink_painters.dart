import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/ui/reader/ink_brush_spec.dart';
import 'package:shuaqi/ui/reader/ink_ribbon.dart';

/// 已提交笔迹的增量绘制缓存（挂在 InkLayer 的 State 上，跨 painter 实例存活）。
///
/// ## 结构
/// 每个 [InkBrushSpec]（笔刷 + 颜色 + 粗细）一条 [InkRibbon]：
/// - `pen` / `ballpoint`：不透明墨色，`srcOver`；
/// - `highlighter`：半透明荧光色，亮纸 `multiply` / 暗纸 `screen`，
///   **先画**（垫在墨迹下面），否则荧光笔会给下方已写的字再合一次色。
///
/// ## 增量
/// InkDoc 不可变、只追加：抬笔时只往对应 ribbon append 这一笔（O(本笔点数)），
/// 整层只在"有新笔"时重绘一次，每次重绘 = 每种 (笔刷,色,粗) 最多 24 次 `drawPath`。
/// strokeCount 变少（清空 / 擦除）时整体重建。
///
/// ## 换纸 = 整体重建
/// 颜色按"纸的明暗"解析（夜读纸用同色相提亮版），所以纸样式一变，所有 spec 都变。
/// 换纸是用户手动动作（不是每帧），一次性 O(笔画数) 重放可以接受；
/// 换来的是"每一笔都按当前纸取色"的正确性（切到夜读，旧笔迹自动变暖白）。
class CommittedInkCache {
  CommittedInkCache();

  /// spec → 几何。用 Map 而不是固定三条：颜色/粗细是用户可选的组合。
  final Map<InkBrushSpec, InkRibbon> _ribbons = <InkBrushSpec, InkRibbon>{};

  int _paintedStrokeCount = 0;
  bool _darkPaper = false;
  int _epoch = -1;

  /// 当前缓存里的组合数（HUD / 单测用）。
  int get specCount => _ribbons.length;

  /// 与新 [InkDoc] 同步：只 append 新增的笔画。
  ///
  /// [epoch] 是控制器的"结构性改动"计数（擦除 / 撤销 / 重做 / 清空都会 +1）。
  /// 那些操作让笔迹集合**既不是纯追加、长度也可能不变**（一笔换两笔），
  /// 只比 `strokeCount` 会漏判，所以 epoch 一变就整体重建。
  void sync(InkDoc doc, {required bool darkPaper, required int epoch}) {
    // 纸的明暗变了：所有取色都要重算；epoch 变了：前缀不再可信。两者都整体重建。
    if (darkPaper != _darkPaper || epoch != _epoch) {
      _darkPaper = darkPaper;
      _epoch = epoch;
      clear();
    }
    if (doc.strokeCount < _paintedStrokeCount) {
      clear();
    }
    for (int i = _paintedStrokeCount; i < doc.strokes.length; i++) {
      final InkStroke stroke = doc.strokes[i];
      final InkBrushSpec spec = InkBrushSpec.of(
        style: stroke.style,
        colorIndex: stroke.colorIndex,
        brushWidth: stroke.brushWidth,
        darkPaper: _darkPaper,
      );
      _ribbons.putIfAbsent(spec, () => InkRibbon(spec)).addStroke(stroke);
    }
    _paintedStrokeCount = doc.strokeCount;
  }

  void draw(Canvas canvas) {
    if (_ribbons.isEmpty) {
      return;
    }
    // 顺序稳定：荧光笔垫底（spec.compare 里定死），保证同一份数据每次画得一样。
    final List<InkBrushSpec> specs = _ribbons.keys.toList()
      ..sort(InkBrushSpec.compare);
    for (final InkBrushSpec spec in specs) {
      _ribbons[spec]!.draw(canvas);
    }
  }

  void clear() {
    for (final InkRibbon ribbon in _ribbons.values) {
      ribbon.clear();
    }
    _ribbons.clear();
    _paintedStrokeCount = 0;
  }
}

/// 已提交层。只在"有新笔提交 / 换纸 / 显示倍率变化"时重绘。
///
/// 注意 [shouldRepaint] 必须比较 doc 身份：InkDoc 不可变，每次 commit
/// 都是新实例；缓存（[CommittedInkCache]）是跨 painter 存活的对象，
/// 不比较 doc 会把新 append 的笔画吞掉（painter 不重绘 → 看不见）。
class CommittedInkPainter extends CustomPainter {
  CommittedInkPainter({
    required this.cache,
    required this.doc,
    required this.scale,
    required this.darkPaper,
  });

  final CommittedInkCache cache;
  final InkDoc doc;

  /// 当前纸的明暗。**必须参与 shouldRepaint**：换纸时 [cache] 是同一个对象，
  /// 只在 sync 里重建了 ribbon；如果这里不比较 darkPaper，画布会认为
  /// "doc/scale 都没变"而拒绝重绘，旧墨迹会保持深色（夜读纸上几乎看不见）。
  final bool darkPaper;

  /// 内容坐标（pt）→ 本地逻辑像素的倍率：`displayWidth / pageWidthPt`。
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    if (scale <= 0) {
      return;
    }
    canvas.save();
    canvas.scale(scale);
    cache.draw(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CommittedInkPainter oldDelegate) {
    return oldDelegate.doc != doc ||
        oldDelegate.scale != scale ||
        oldDelegate.darkPaper != darkPaper;
  }
}

/// 正在写的这一笔。几何由 [InkRibbon] 流式累加，逐帧只重绘这一层。
///
/// `repaint` 是 `ValueNotifier<int>`（每次 append 自增）：落笔路径上只
/// `value++`，不 setState（INV-01）。
class ActiveStrokePainter extends CustomPainter {
  ActiveStrokePainter({
    required this.ribbon,
    required this.scale,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final InkRibbon ribbon;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    if (scale <= 0) {
      return;
    }
    canvas.save();
    canvas.scale(scale);
    ribbon.draw(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ActiveStrokePainter oldDelegate) {
    return oldDelegate.ribbon != ribbon || oldDelegate.scale != scale;
  }
}

/// 色块预览用：这个颜色"在纸上实际是什么颜色"。
///
/// 与绘制层走**同一条**解析路径（[InkBrushSpec.of]），
/// 避免"选色预览和落笔颜色不一样"这类只有真机才看得出的偏差。
Color previewColorOf({
  required InkStrokeStyle style,
  required int colorIndex,
  required bool darkPaper,
}) {
  return InkBrushSpec.of(
    style: style,
    colorIndex: colorIndex,
    brushWidth: InkStroke.defaultBrushWidth,
    darkPaper: darkPaper,
  ).color;
}
