import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_palette.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';

/// 一支"选中态"的笔：工具 + 颜色 + 粗细（纯 Dart，可单测）。
///
/// 这是**工具的设置**，不是笔迹的属性：落笔时把这三个值写进 [InkStroke]
/// （colorIndex / brushWidth 进数据契约，见 ink_doc.dart 的说明）。
class InkBrush {
  const InkBrush({
    this.tool = InkTool.pen,
    this.colorIndex = 0,
    this.brushWidth = InkStroke.defaultBrushWidth,
    this.darkPaper = false,
  });

  final InkTool tool;

  /// 调色板索引。换工具时会被收敛到该工具的颜色数量内（荧光笔只有 4 色）。
  final int colorIndex;

  /// 粗细 0..100（橡皮用它表示"大小"，见 [Eraser.radiusOfWidth]）。
  final int brushWidth;

  /// 当前纸是不是暗纸（夜读）。**只影响 UI 上的取色预览**，
  /// 落笔时的真实颜色由绘制层按纸样式解析（同一笔在昼夜纸上都能看清）。
  final bool darkPaper;

  InkStrokeStyle get strokeStyle => tool.strokeStyle ?? InkStrokeStyle.pen;

  bool get isEraser => tool.isEraser;

  /// 当前选择下真正画到纸上的 ARGB（UI 预览、调试用）。
  int get argb => InkPalette.argb(
    style: strokeStyle,
    index: colorIndex,
    darkPaper: darkPaper,
  );

  InkBrush copyWith({
    InkTool? tool,
    int? colorIndex,
    int? brushWidth,
    bool? darkPaper,
  }) {
    final InkTool nextTool = tool ?? this.tool;
    final InkStrokeStyle style = nextTool.strokeStyle ?? InkStrokeStyle.pen;
    final int nextColor = InkPalette.clampIndex(
      style,
      colorIndex ?? this.colorIndex,
    );
    return InkBrush(
      tool: nextTool,
      colorIndex: nextColor,
      brushWidth: (brushWidth ?? this.brushWidth).clamp(
        InkStroke.brushWidthMin,
        InkStroke.brushWidthMax,
      ),
      darkPaper: darkPaper ?? this.darkPaper,
    );
  }

  /// 只换工具，并保证颜色/粗细在该工具允许的范围内。
  InkBrush withTool(InkTool tool) => copyWith(tool: tool);

  @override
  bool operator ==(Object other) =>
      other is InkBrush &&
      other.tool == tool &&
      other.colorIndex == colorIndex &&
      other.brushWidth == brushWidth &&
      other.darkPaper == darkPaper;

  @override
  int get hashCode => Object.hash(tool, colorIndex, brushWidth, darkPaper);

  // ── 持久化（setting 表里的一个短字符串）─────────────────────────────
  //
  // 格式：`v2:pen:0:50;v2:highlighter:2:85;...`（版本:tool:color:width）
  // 为什么不用 JSON：这是 app 内部状态，不需要跨语言读；短字符串出问题时
  // 一眼能看懂，而且解析失败只丢"上次用的笔"，不值得为它引入 JSON 依赖。
  //
  // ## 为什么要版本前缀（2026-10-23）
  // 粗细从"三档枚举 0/1/2"变成了"0..100"。旧值 `pen:0:2` 如果按新语义解析
  // 就是 2%（极细）——实测真机上笔迹直接细成发丝。前缀让两种格式可区分：
  // 没有 `v2:` 的一律当旧值，按 0→15 / 1→50 / 2→85 映射。

  static const String _formatPrefix = 'v2:';

  static String encodeAll(Iterable<InkBrush> brushes) => brushes
      .map(
        (InkBrush b) =>
            '$_formatPrefix${b.tool.name}:${b.colorIndex}:${b.brushWidth}',
      )
      .join(';');

  /// 旧三档 → 0..100 的映射（细/中/粗）。
  static const List<int> legacyWidthMap = <int>[15, 50, 85];

  /// 解析失败一律跳过该条；全部失败时由调用方用默认值兜底（绝不抛）。
  static Map<InkTool, InkBrush> decodeAll(String? raw) {
    final Map<InkTool, InkBrush> result = <InkTool, InkBrush>{};
    if (raw == null || raw.isEmpty) {
      return result;
    }
    for (final String chunk in raw.split(';')) {
      final bool legacy = !chunk.startsWith(_formatPrefix);
      final String body = legacy
          ? chunk
          : chunk.substring(_formatPrefix.length);
      final List<String> parts = body.split(':');
      if (parts.length < 3) {
        continue;
      }
      final InkTool tool = InkTool.byName(parts[0]);
      final int? color = int.tryParse(parts[1]);
      final int? rawWidth = int.tryParse(parts[2]);
      if (color == null || rawWidth == null) {
        continue;
      }
      // 旧格式：0/1/2 三档 → 15/50/85；越界也按中档处理
      final int width = legacy
          ? legacyWidthMap[rawWidth.clamp(0, legacyWidthMap.length - 1)]
          : rawWidth;
      result[tool] = InkBrush(
        tool: tool,
        colorIndex: color,
        brushWidth: width,
      ).copyWith();
    }
    return result;
  }
}
