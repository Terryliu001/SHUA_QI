import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/reader/ink_ribbon.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 已提交笔迹的增量绘制缓存（挂在 InkLayer 的 State 上，跨 painter 实例存活）。
///
/// ## 结构
/// 每个笔刷一条 [InkRibbon]（各自一套宽度档位与混合模式）：
/// - `pen` / `ballpoint`：不透明墨色，`srcOver`；
/// - `highlighter`：半透明 + `multiply`，**先画**（垫在墨迹下面），
///   否则荧光笔会给下方已写的字再乘一次色。
///
/// ## 增量
/// InkDoc 不可变、只追加：抬笔时只往对应 ribbon append 这一笔（O(本笔点数)），
/// 整层只在"有新笔"时重绘一次，每次重绘最多 3 × 24 次 `drawPath`。
/// strokeCount 变少（清空 / T2.3 的擦除）时整体重建。
///
/// ## 抬笔不跳变
/// ribbon 的构造与"正在写的这一笔"（[ActiveStrokePainter]）完全同源：
/// 同样的压力平滑、同样的档位量化、同样的 Path。抬笔只是把同一份几何
/// 从活动层搬到已提交层，像素级一致。
class CommittedInkCache {
  CommittedInkCache({Color inkColor = ShqPalette.ink})
    : _ribbons = <InkStrokeStyle, InkRibbon>{
        InkStrokeStyle.pen: InkRibbon(
          style: InkStrokeStyle.pen,
          color: inkColor,
        ),
        InkStrokeStyle.ballpoint: InkRibbon(
          style: InkStrokeStyle.ballpoint,
          color: inkColor,
        ),
        InkStrokeStyle.highlighter: InkRibbon(
          style: InkStrokeStyle.highlighter,
          color: ShqPalette.highlighter,
          blendMode: BlendMode.multiply,
        ),
      };

  /// 绘制顺序：荧光笔在下，普通墨迹在上。
  static const List<InkStrokeStyle> _drawOrder = <InkStrokeStyle>[
    InkStrokeStyle.highlighter,
    InkStrokeStyle.pen,
    InkStrokeStyle.ballpoint,
  ];

  final Map<InkStrokeStyle, InkRibbon> _ribbons;

  int _paintedStrokeCount = 0;

  /// 与新 [InkDoc] 同步：只 append 新增的笔画。
  void sync(
    InkDoc doc, {
    required Color inkColor,
    required Color highlighterColor,
  }) {
    _ribbons[InkStrokeStyle.pen]!.color = inkColor;
    _ribbons[InkStrokeStyle.ballpoint]!.color = inkColor;
    _ribbons[InkStrokeStyle.highlighter]!.color = highlighterColor;

    if (doc.strokeCount < _paintedStrokeCount) {
      clear();
    }
    for (int i = _paintedStrokeCount; i < doc.strokes.length; i++) {
      final InkStroke stroke = doc.strokes[i];
      _ribbons[stroke.style]!.addStroke(stroke);
    }
    _paintedStrokeCount = doc.strokeCount;
  }

  void draw(Canvas canvas) {
    for (final InkStrokeStyle style in _drawOrder) {
      _ribbons[style]!.draw(canvas);
    }
  }

  void clear() {
    for (final InkRibbon ribbon in _ribbons.values) {
      ribbon.clear();
    }
    _paintedStrokeCount = 0;
  }
}

/// 已提交层。只在"有新笔提交 / 墨色变化 / 显示倍率变化"时重绘。
///
/// 注意 [shouldRepaint] 必须比较 doc 身份：InkDoc 不可变，每次 commit
/// 都是新实例；缓存（[CommittedInkCache]）是跨 painter 存活的对象，
/// 不比较 doc 会把新 append 的笔画吞掉（painter 不重绘 → 看不见）。
class CommittedInkPainter extends CustomPainter {
  CommittedInkPainter({
    required this.cache,
    required this.doc,
    required this.scale,
    required this.inkColor,
    required this.highlighterColor,
  });

  final CommittedInkCache cache;
  final InkDoc doc;

  /// 内容坐标（pt）→ 本地逻辑像素的倍率：`displayWidth / pageWidthPt`。
  final double scale;
  final Color inkColor;
  final Color highlighterColor;

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
        oldDelegate.inkColor != inkColor ||
        oldDelegate.highlighterColor != highlighterColor;
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
    required this.color,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final InkRibbon ribbon;
  final double scale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (scale <= 0) {
      return;
    }
    canvas.save();
    canvas.scale(scale);
    ribbon.color = color;
    ribbon.draw(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ActiveStrokePainter oldDelegate) {
    return oldDelegate.ribbon != ribbon ||
        oldDelegate.scale != scale ||
        oldDelegate.color != color;
  }
}

/// 墨色按**纸样式**取（不是按 App 主题取 —— 见 [PaperStyle] 的说明）。
///
/// 暗纸（夜读）用暖白墨，其余用深墨。判定的唯一来源是 `PaperStyle.isDarkPaper`，
/// UI 层不许自己写 `== PaperStyle.night`，也不许看 `Theme.brightness`：
/// 浅色界面 + 夜读纸、深色界面 + 原图纸都是合法组合。
Color inkColorFor(PaperStyle paper) =>
    paper.isDarkPaper ? ShqNight.ink : ShqPalette.ink;

/// 荧光笔的合成色（不随纸样式变化：它是"透明荧光膜"，乘在纸与字上）。
const Color highlighterColorOf = ShqPalette.highlighter;
