import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/export/export_options.dart';

/// 导出选项的组合规则。看起来简单，但"关掉原题笔迹怎么办""导出的到底是什么"
/// 这类问题一旦含糊，用户点出来的 PDF 就不是他以为的那份。
void main() {
  test('默认是「原题 + 笔迹」', () {
    const ExportOptions options = ExportOptions();
    expect(options.original, isTrue);
    expect(options.ink, isTrue);
    expect(options.answer, isFalse);
    expect(options.summary, '原题 + 笔迹');
  });

  test('关掉原题时笔迹一起关掉（没有落点）', () {
    const ExportOptions options = ExportOptions(original: true, ink: true);
    final ExportOptions next = options.copyWith(original: false);
    expect(next.original, isFalse);
    expect(next.ink, isFalse);
    expect(next.effectiveInk, isFalse);
    expect(next.canExport, isFalse, reason: '只剩空组合，不该允许导出');
  });

  test('只要答题卡也能导出', () {
    final ExportOptions options = const ExportOptions().toggle(ExportPart.original);
    expect(options.original, isFalse);
    expect(options.answer, isFalse);
    final ExportOptions withAnswer = options.toggle(ExportPart.answer);
    expect(withAnswer.canExport, isTrue);
    expect(withAnswer.summary, '答题卡');
  });

  test('三个开关的 summary 与顺序稳定', () {
    expect(ExportOptions.originalOnly.summary, '原题');
    expect(ExportOptions.withInk.summary, '原题 + 笔迹');
    expect(ExportOptions.full.summary, '原题 + 笔迹 + 答题卡');
    expect(ExportOptions.answerOnly.summary, '答题卡');
  });

  test('预设互相对得上（点预设再点开关不会错位）', () {
    for (final ({String label, ExportOptions options}) preset
        in ExportOptions.presets) {
      expect(
        ExportOptions(
          original: preset.options.original,
          ink: preset.options.effectiveInk,
          answer: preset.options.answer,
        ).matches(preset.options),
        isTrue,
        reason: preset.label,
      );
    }
    // 「原题」与「原题+笔迹」不能同时被判定为当前选中。
    expect(ExportOptions.originalOnly.matches(ExportOptions.withInk), isFalse);
  });

  test('文件内容段：四种常用组合有短名字，非标准组合用 + 拼', () {
    expect(ExportOptions.originalOnly.fileTag, '纯试卷');
    expect(ExportOptions.withInk.fileTag, '试卷+笔迹');
    expect(ExportOptions.full.fileTag, '完整存档');
    expect(ExportOptions.answerOnly.fileTag, '答题卡');
    expect(
      const ExportOptions(original: true, ink: false, answer: true).fileTag,
      '原题+答题卡',
    );
  });

  test('文件名：卷名 + 内容 + 时间戳，清理非法字符', () {
    final DateTime at = DateTime(2026, 10, 25, 22, 5);
    final String name = exportFileName(
      '2019–2020/线性代数:期末*试题',
      at,
      options: ExportOptions.full,
    );
    expect(name.startsWith('2019–2020 线性代数 期末 试题'), isTrue);
    expect(name.contains('完整存档'), isTrue);
    expect(name.endsWith('_20261025-2205.pdf'), isTrue);
    expect(name.contains('/'), isFalse);
    expect(name.contains(':'), isFalse);
    expect(name.contains('*'), isFalse);
  });

  test('文件名：可手改；自动补 .pdf；空名字回退默认', () {
    final DateTime at = DateTime(2026, 10, 25, 22, 5);
    expect(
      exportFileName('原卷', at, customName: '我的 错题 整理'),
      '我的 错题 整理.pdf',
    );
    expect(
      exportFileName('原卷', at, customName: '我的整理.pdf'),
      '我的整理.pdf',
    );
    // 只有非法字符时回退到标题命名。
    expect(
      exportFileName('原卷', at, customName: '///'),
      startsWith('原卷_试卷+笔迹_20261025-2205.pdf'),
    );
    // 标题过长时截断，给内容与时间戳留位置。
    final String long = exportFileName('题' * 80, at);
    expect(long.length, lessThan(32 + 30));
    expect(long.contains('试卷+笔迹'), isTrue);
  });

  test('文件名：空白标题回退「试卷」', () {
    final DateTime at = DateTime(2026, 10, 25, 22, 5);
    expect(
      exportFileName('   ', at),
      '试卷_试卷+笔迹_20261025-2205.pdf',
    );
  });
}
