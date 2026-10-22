import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 工具栏上的"工具"（T2.3 起含橡皮）。纯 Dart。
///
/// ## 为什么工具 ≠ [InkStrokeStyle]
/// `InkStrokeStyle` 是**数据契约**的一部分（SIF v1 里 style 占 1 字节：0 钢笔 / 1 圆珠笔 /
/// 2 荧光笔，§5.4）。橡皮**不产生笔画**，把它塞进 `InkStrokeStyle` 会污染入库格式
/// （还会诱导后人给橡皮也存一笔"擦除笔迹"，那是位图橡皮的思路）。
/// 所以"工具"是 UI 概念：画什么笔、还是擦。
enum InkTool {
  pen(InkStrokeStyle.pen, '钢笔'),
  ballpoint(InkStrokeStyle.ballpoint, '圆珠笔'),
  highlighter(InkStrokeStyle.highlighter, '荧光笔'),
  eraser(null, '橡皮');

  const InkTool(this.strokeStyle, this.label);

  /// 这个工具落笔时用的笔画样式；橡皮为 null（它不产生笔画）。
  final InkStrokeStyle? strokeStyle;

  /// 工具栏显示名。文字比图标诚实（钢笔/圆珠笔在 Material 里没有可区分字形）。
  final String label;

  bool get isEraser => this == InkTool.eraser;

  /// 从持久化的名字解析（非法/缺失一律回落钢笔：一笔画不出来比多一步更糟）。
  static InkTool byName(Object? raw) {
    for (final InkTool tool in InkTool.values) {
      if (tool.name == raw) {
        return tool;
      }
    }
    return InkTool.pen;
  }
}
