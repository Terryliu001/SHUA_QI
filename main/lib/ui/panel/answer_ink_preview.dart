import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/ui/reader/ink_painters.dart';

/// 答题卡手写的"纸面预览"：白纸 + 浅横线 + 真实笔迹。
///
/// 为什么是实时绘制而不是截图：改作答框、翻页、调完框回来都要看最新笔迹，
/// 截图会一直是旧的；`CommittedInkCache` 已经是现成的批量绘制路径，成本很低。
///
/// 坐标系固定按 [AnswerCanvas] 的 1000×600pt 缩放（SIF 里的坐标就是这套）。
class AnswerInkPreview extends StatelessWidget {
  const AnswerInkPreview({
    super.key,
    required this.doc,
    this.canvasWidth = 1000,
    this.canvasHeight = 600,
    this.showLines = true,
    this.region,
  });

  final InkDoc doc;

  /// 笔迹所在的虚拟画布尺寸（pt）。默认是答题卡的 1000×600。
  final double canvasWidth;
  final double canvasHeight;

  final bool showLines;

  /// 只看页面里的某一块（PDF 页内笔迹用它）。
  ///
  /// 给了 region 时，坐标空间就是**页面 pt**：按 `region` 的宽高铺满，
  /// 再平移到那块区域的左上角。不给则按 [canvasWidth]×[canvasHeight] 的虚拟画布。
  final RegionRect? region;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _AnswerInkPainter(
        doc: doc,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        showLines: showLines,
        region: region,
      ),
      size: Size.infinite,
    );
  }
}

class _AnswerInkPainter extends CustomPainter {
  _AnswerInkPainter({
    required this.doc,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.showLines,
    this.region,
  });

  final InkDoc doc;
  final double canvasWidth;
  final double canvasHeight;
  final bool showLines;
  final RegionRect? region;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFEFB),
    );
    if (showLines) {
      final Paint line = Paint()
        ..color = const Color(0xFFE5DFD3)
        ..strokeWidth = 1;
      const double gap = 16;
      for (double y = gap; y < size.height; y += gap) {
        canvas.drawLine(Offset(3, y), Offset(size.width - 3, y), line);
      }
    }
    if (doc.strokes.isEmpty) {
      return;
    }
    canvas.save();
    final RegionRect? area = region;
    if (area != null && area.width > 0 && area.height > 0) {
      // 页面坐标：把这块区域铺满预览框。
      canvas.scale(size.width / area.width, size.height / area.height);
      canvas.translate(-area.left, -area.top);
    } else {
      canvas.scale(size.width / canvasWidth, size.height / canvasHeight);
    }
    final CommittedInkCache ink = CommittedInkCache()
      ..sync(doc, darkPaper: false, epoch: doc.revision);
    ink.draw(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AnswerInkPainter oldDelegate) =>
      oldDelegate.doc != doc ||
      oldDelegate.doc.revision != doc.revision ||
      oldDelegate.canvasWidth != canvasWidth ||
      oldDelegate.canvasHeight != canvasHeight ||
      oldDelegate.showLines != showLines ||
      oldDelegate.region != region;
}
