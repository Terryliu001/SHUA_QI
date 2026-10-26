/// 导出选项（纯 Dart）：这一段逻辑不碰 IO，只决定"导出里有什么"。
///
/// 用户的三种用法其实是一组**可组合**的开关：
/// - 原题（PDF 页）
/// - 笔迹（铺在原题页上）
/// - 答题卡（每道**有作答**的题：题图 + 作答纸，附在最后）
///
/// 组合出来正好是三件事：
/// | 组合 | 结果 |
/// |---|---|
/// | 原题 | 干净的卷子（打印/分享） |
/// | 原题 + 笔迹 | 我做过的卷子（老师/同学看过程） |
/// | 原题 + 笔迹 + 答题卡 | 完整存档 |
/// | 答题卡 | 只有题目与作答的整理稿 |
library;

/// 导出清晰度（2026-10-26 用户第 14 条：图片和输出 PDF 清晰度）。
///
/// 代价是**体积与内存**：每页位图宽 2400px 时，A4 一页约 32MB（1700px 约 15MB），
/// 导出 20 页要逐页编码释放，不能一次全驻留。
enum ExportQuality {
  /// 1700px 宽（A4 ≈ 205dpi）：体积小，屏幕上够看。
  standard('标准', '体积小，发微信/群里不卡'),

  /// 2400px 宽（A4 ≈ 290dpi）：打印清晰，文件约大一倍。
  high('高清', '打印更清晰，文件约大一倍');

  const ExportQuality(this.label, this.hint);

  final String label;
  final String hint;

  /// 每页导出的像素宽。
  int get pageWidthPx => switch (this) {
    ExportQuality.standard => 1700,
    ExportQuality.high => 2400,
  };
}

enum ExportPart {
  original('原题', '试卷每一页的原样'),
  ink('笔迹', '把写在上面的字合并进页面'),
  answer('答题卡', '每题题图 + 作答纸（只附有作答的题）');

  const ExportPart(this.label, this.hint);

  final String label;
  final String hint;
}

class ExportOptions {
  const ExportOptions({
    this.original = true,
    this.ink = true,
    this.answer = false,
    this.quality = ExportQuality.high,
  });

  final bool original;
  final bool ink;
  final bool answer;

  /// 清晰度（默认高清：用户抱怨的就是"不够清晰"）。
  final ExportQuality quality;

  bool get isEmpty => !original && !ink && !answer;

  /// 笔迹必须铺在原题页上：没有原题时"只有笔迹的空白页"没有意义，
  /// 所以界面上会把它一起关掉（而不是生成一堆半透明空页）。
  bool get effectiveInk => ink && original;

  /// 至少要有能出页的一项。
  bool get canExport => original || answer;

  String get summary {
    final List<String> parts = <String>[
      if (original) '原题',
      if (effectiveInk) '笔迹',
      if (answer) '答题卡',
    ];
    return parts.isEmpty ? '什么也没选' : parts.join(' + ');
  }

  ExportOptions copyWith({
    bool? original,
    bool? ink,
    bool? answer,
    ExportQuality? quality,
  }) {
    final bool nextOriginal = original ?? this.original;
    return ExportOptions(
      original: nextOriginal,
      // 关掉原题时把笔迹一起关掉（它没有落点）。
      ink: nextOriginal ? (ink ?? this.ink) : false,
      answer: answer ?? this.answer,
      quality: quality ?? this.quality,
    );
  }

  /// 点某个开关。返回新选项，规则集中在这里，UI 不重复判断。
  ExportOptions toggle(ExportPart part) => switch (part) {
    ExportPart.original => copyWith(original: !original),
    ExportPart.ink => copyWith(ink: !ink),
    ExportPart.answer => copyWith(answer: !answer),
  };

  static const ExportOptions originalOnly = ExportOptions(
    original: true,
    ink: false,
    answer: false,
  );

  static const ExportOptions withInk = ExportOptions(
    original: true,
    ink: true,
    answer: false,
  );

  static const ExportOptions full = ExportOptions(
    original: true,
    ink: true,
    answer: true,
  );

  static const ExportOptions answerOnly = ExportOptions(
    original: false,
    ink: false,
    answer: true,
  );

  /// 当前选项最接近哪个预设（UI 用来高亮）。
  static const List<({String label, ExportOptions options})> presets =
      <({String label, ExportOptions options})>[
        (label: '纯试卷', options: originalOnly),
        (label: '试卷 + 笔迹', options: withInk),
        (label: '完整存档', options: full),
        (label: '只要答题卡', options: answerOnly),
      ];

  bool matches(ExportOptions other) =>
      original == other.original &&
      effectiveInk == other.effectiveInk &&
      answer == other.answer;
}

/// 导出文件名：`SHUAQI_卷名_20261025-2215.pdf`。
///
/// 去掉文件系统不接受的字符（`/ \ : * ? " < > |`）与控制字符；
/// 标题过长时截断到 40 字，避免某些文件管理器显示成 `…`。
String exportFileName(String title, DateTime at) {
  String safe = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ');
  safe = safe.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (safe.isEmpty) {
    safe = '试卷';
  }
  if (safe.length > 40) {
    safe = safe.substring(0, 40).trim();
  }
  final String stamp =
      '${at.year}'
      '${at.month.toString().padLeft(2, '0')}'
      '${at.day.toString().padLeft(2, '0')}'
      '-'
      '${at.hour.toString().padLeft(2, '0')}'
      '${at.minute.toString().padLeft(2, '0')}';
  return 'SHUAQI_${safe}_$stamp.pdf';
}
