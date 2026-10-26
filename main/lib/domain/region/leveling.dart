/// 层级判定（纯 Dart）：把题号分成大题 / 小题两级。
///
/// ## 为什么"样式优先、字号兜底"（2026-10-23 真机数据推翻了原方案）
///
/// 规格原本的判定是"字号跳变 ≥1.15 倍即大题"。真实试卷实测（`math_analysis_midterm`）
/// 发现这个信号**不可用**：pdfium 给的多行公式文本对象会把 `bounds.height`
/// 报成整个对象的跨度（`设𝑓(𝑥)={…}` 那一行的片段高度全是 29.1pt，而正文只有 11.6pt）。
/// 于是"第 1 题"会被误判成比"一、填空题"更大的字号 → 层级翻车。
///
/// 现行判定顺序（逐级降级，命中即停）：
/// 1. **样式**：中文数字 / 罗马数字 / `【例 x】` → 大题；`（3）` / `①` → 小题；
/// 2. **两级并存**：同一卷里既有 `1.` 又有 `（1）` → 前者大题、后者小题（最常见的小节结构）；
/// 3. **字号**：只在题号样式**全是同一种**（没法区分）时，才用字号断层判断；
/// 4. 都不成立 → 全卷同级（都是小题）。
///
/// 层级只决定"谁切断谁的区域"，判错只会让框大小不对，不会丢题（区域永远从题号行开始）。
library;

import 'package:shuaqi/domain/region/pattern.dart';

/// 层级判定的结果。带 `splitByFont` / `threshold` 便于日志解释"为什么这么分"。
class Leveling {
  const Leveling({required this.levels, required this.basis, this.threshold});

  /// 与输入顺序一一对应：1 = 大题，2 = 小题。
  final List<int> levels;

  /// 依据：`style` / `mixed` / `font` / `none`。
  final String basis;

  /// 字号阈值（pt），只有 [basis] == 'font' 时有值。
  final double? threshold;

  bool get splitByFont => basis == 'font';

  int get majorCount => levels.where((int level) => level == 1).length;

  int get minorCount => levels.where((int level) => level == 2).length;
}

/// [kinds] 与 [fontSizes] 长度必须一致，顺序即文档顺序。
Leveling assignLevels(
  List<MarkKind> kinds,
  List<double> fontSizes, {
  double fontJumpRatio = 1.15,
  bool allowFontFallback = true,
}) {
  final int count = kinds.length;
  assert(fontSizes.length == count, 'kinds 与 fontSizes 必须等长');
  if (count == 0) {
    return const Leveling(levels: <int>[], basis: 'none');
  }

  // 1) 样式直接给结论
  final bool hasMajorStyle = kinds.any(_prefersMajorKind);
  if (hasMajorStyle) {
    return Leveling(
      levels: <int>[
        for (final MarkKind kind in kinds) _prefersMajorKind(kind) ? 1 : 2,
      ],
      basis: 'style',
    );
  }

  // 2) `1.` 与 `（1）` 并存 → 前者大题
  final bool hasArabic = kinds.any(_isArabicKind);
  final bool hasParen = kinds.contains(MarkKind.parenArabic);
  if (hasArabic && hasParen) {
    return Leveling(
      levels: <int>[
        for (final MarkKind kind in kinds) _isArabicKind(kind) ? 1 : 2,
      ],
      basis: 'mixed',
    );
  }

  // 3) 只能靠字号断层
  //
  // 扫描件不走这一步：行高是"像素行段"估出来的，倾斜/上下标/公式会让同级的
  // 两个字差 1.3 倍以上，字号断层会把好好的题判成"大题容器"（真机第 1 页
  // 第 8 题因此整道消失）。扫描件的层级只信字形（中文序号 vs 数字/括号）。
  final _Gap? gap = allowFontFallback ? _largestGap(fontSizes) : null;
  if (gap != null && gap.ratio >= fontJumpRatio) {
    return Leveling(
      levels: <int>[
        for (final double size in fontSizes) size >= gap.upper ? 1 : 2,
      ],
      basis: 'font',
      threshold: gap.upper,
    );
  }

  // 4) 全卷同级
  return Leveling(
    levels: List<int>.filled(count, 2, growable: false),
    basis: 'none',
  );
}

bool _prefersMajorKind(MarkKind kind) =>
    kind == MarkKind.cnNumeral ||
    kind == MarkKind.roman ||
    kind == MarkKind.example;

bool _isArabicKind(MarkKind kind) =>
    kind == MarkKind.arabic || kind == MarkKind.thQuestion;

class _Gap {
  const _Gap({required this.lower, required this.upper, required this.ratio});

  /// 小字号组的最大字号。
  final double lower;

  /// 大字号组的最小字号。
  final double upper;

  /// `upper / lower`。
  final double ratio;
}

/// 在字号集合里找相邻两档中**相对差最大**的那一处。
///
/// 只比较不同取值；不同取值不足 2 个时返回 null。
_Gap? _largestGap(List<double> sizes) {
  final List<double> distinct =
      sizes.where((double value) => value > 0).toSet().toList(growable: false)
        ..sort();
  if (distinct.length < 2) {
    return null;
  }
  _Gap? best;
  for (int i = 1; i < distinct.length; i++) {
    final double lower = distinct[i - 1];
    final double upper = distinct[i];
    if (lower <= 0) {
      continue;
    }
    final double ratio = upper / lower;
    if (best == null || ratio > best.ratio) {
      best = _Gap(lower: lower, upper: upper, ratio: ratio);
    }
  }
  return best;
}
