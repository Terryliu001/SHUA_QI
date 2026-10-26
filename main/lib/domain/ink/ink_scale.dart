import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 把一份笔迹从一种纸张尺寸搬到另一种（按比例）。
///
/// 为什么需要它（2026-10-24）：答题卡纸张现在可以改（默认 1000×600 / A4 / B5），
/// 而 SIF 里的坐标是**纸张绝对值 pt**。改了纸张之后旧笔迹还按旧尺寸解释，
/// 就会全挤到左上角。这里按 `新宽/旧宽`、`新高/旧高` 缩放，笔迹的相对位置保持不变。
///
/// 纯函数，不改入参、不动 uid / 样式 / 粗细。
InkDoc scaleInkDoc(
  InkDoc doc, {
  required double fromWidth,
  required double fromHeight,
  required double toWidth,
  required double toHeight,
}) {
  if (doc.strokes.isEmpty) {
    return doc;
  }
  if (fromWidth <= 0 ||
      fromHeight <= 0 ||
      toWidth <= 0 ||
      toHeight <= 0) {
    return doc;
  }
  if ((fromWidth - toWidth).abs() < 0.01 &&
      (fromHeight - toHeight).abs() < 0.01) {
    return doc;
  }
  final double sx = toWidth / fromWidth;
  final double sy = toHeight / fromHeight;
  return InkDoc(
    revision: doc.revision,
    strokes: <InkStroke>[
      for (final InkStroke stroke in doc.strokes)
        InkStroke(
          uid: stroke.uid,
          style: stroke.style,
          colorIndex: stroke.colorIndex,
          brushWidth: stroke.brushWidth,
          points: <InkPoint>[
            for (final InkPoint point in stroke.points)
              InkPoint(
                x: point.x * sx,
                y: point.y * sy,
                pressure: point.pressure,
                t: point.t,
              ),
          ],
        ),
    ],
  );
}
