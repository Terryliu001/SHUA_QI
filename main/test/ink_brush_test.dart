import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_brush.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';

/// `InkBrush` 的持久化与收敛（纯 Dart）。
///
/// 重点保两件事：
/// 1. 新格式（`v2:` 前缀）往返不丢颜色/粗细；
/// 2. **旧格式（三档 0/1/2）要被正确迁移**——否则粗细会从"中档"变成"2%"，
///    真机上笔迹细成发丝（2026-10-23 实测踩过）。
void main() {
  test('新格式往返：四支笔的工具/颜色/粗细都保留', () {
    const List<InkBrush> source = <InkBrush>[
      InkBrush(tool: InkTool.pen, colorIndex: 2, brushWidth: 63),
      InkBrush(tool: InkTool.ballpoint, colorIndex: 5, brushWidth: 12),
      InkBrush(tool: InkTool.highlighter, colorIndex: 3, brushWidth: 88),
      InkBrush(tool: InkTool.eraser, colorIndex: 0, brushWidth: 24),
    ];
    final Map<InkTool, InkBrush> back = InkBrush.decodeAll(
      InkBrush.encodeAll(source),
    );
    expect(back.length, 4);
    for (final InkBrush brush in source) {
      expect(back[brush.tool]!.colorIndex, brush.colorIndex);
      expect(back[brush.tool]!.brushWidth, brush.brushWidth);
    }
  });

  test('旧格式（三档）迁移：0/1/2 → 15/50/85，不会变成发丝', () {
    // 旧版本写出来的样子
    final Map<InkTool, InkBrush> parsed = InkBrush.decodeAll(
      'pen:2:1;ballpoint:0:0;highlighter:1:2',
    );
    expect(parsed[InkTool.pen]!.colorIndex, 2);
    expect(parsed[InkTool.pen]!.brushWidth, 50, reason: '旧"中档"必须还是中档');
    expect(parsed[InkTool.ballpoint]!.brushWidth, 15);
    expect(parsed[InkTool.highlighter]!.brushWidth, 85);
  });

  test('旧格式更早的样子（只有工具名）也能读，颜色粗细取默认', () {
    final Map<InkTool, InkBrush> parsed = InkBrush.decodeAll('pen');
    expect(parsed, isEmpty, reason: '缺字段的旧值直接忽略，由调用方回落默认');
  });

  test('脏数据不抛：坏条目跳过，好的照读', () {
    final Map<InkTool, InkBrush> parsed = InkBrush.decodeAll(
      'v2:pen:abc:50;v2:pen:1:999;v2:highlighter:2:80',
    );
    // 第一条坏（color 非数字）被跳过；第二条越界被收敛；第三条正常
    expect(parsed[InkTool.pen]!.brushWidth, InkStroke.brushWidthMax);
    expect(parsed[InkTool.highlighter]!.brushWidth, 80);
  });

  test('换工具时颜色收敛到该工具的颜色数量（荧光笔只有 4 色）', () {
    const InkBrush pen = InkBrush(tool: InkTool.pen, colorIndex: 5);
    final InkBrush highlighter = pen.withTool(InkTool.highlighter);
    expect(highlighter.colorIndex, lessThan(4));
    expect(highlighter.tool, InkTool.highlighter);
  });

  test('粗细越界被夹到 0..100', () {
    expect(const InkBrush(brushWidth: 500).copyWith().brushWidth, 100);
    expect(const InkBrush(brushWidth: -5).copyWith().brushWidth, 0);
  });
}
