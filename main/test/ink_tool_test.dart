import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';

/// T2.3 工具枚举：工具 ≠ 数据契约（橡皮不产生笔画，不许污染 SIF 的 style 字节）。
void main() {
  test('三支笔映射到 InkStrokeStyle，橡皮没有样式', () {
    expect(InkTool.pen.strokeStyle, InkStrokeStyle.pen);
    expect(InkTool.ballpoint.strokeStyle, InkStrokeStyle.ballpoint);
    expect(InkTool.highlighter.strokeStyle, InkStrokeStyle.highlighter);
    expect(InkTool.eraser.strokeStyle, isNull);
    expect(InkTool.eraser.isEraser, isTrue);
    expect(InkTool.pen.isEraser, isFalse);
  });

  test('持久化的名字是稳定契约（旧数据 pen/ballpoint/highlighter 仍可读）', () {
    for (final InkTool tool in InkTool.values) {
      expect(InkTool.byName(tool.name), tool);
    }
    expect(InkTool.byName('pen'), InkTool.pen);
    expect(InkTool.byName('highlighter'), InkTool.highlighter);
  });

  test('非法/缺失值回落钢笔（一笔画不出来比多一步更糟）', () {
    expect(InkTool.byName(null), InkTool.pen);
    expect(InkTool.byName('crayon'), InkTool.pen);
    expect(InkTool.byName(42), InkTool.pen);
  });

  test('每个工具都有中文短名（工具栏直接显示，不靠图标猜）', () {
    for (final InkTool tool in InkTool.values) {
      expect(tool.label, isNotEmpty);
    }
  });
}
