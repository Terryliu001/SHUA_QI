/// 作答指纹与「判题依据是否过期」的纯函数（2026-10-28 v0.1.3）。
///
/// 背景：旧版只在改作答框时把 `ocr_at` 与 `updated_at` 拉开，
/// **新增/擦除笔迹不会改变 `updated_at`**，所以写完字再展开「答题情况」
/// 经常还是旧识别文字；改卷也无法判断「AI 判过之后答案有没有大改」。
///
/// 这里用两层信息解决：
/// 1. [answerSignatureOf]：把「作答框 + 答题卡每张纸的笔迹 + 卷面框内笔迹」
///    压成一个短指纹。任何一笔增加/擦除/改框都会变；
/// 2. [isSignificantAnswerChange]：判题时保存 OCR 文本，之后用归一化后的
///    相似度判断是「小改（保留 AI 原判）」还是「大改（需要重判）」。
///
/// 全部是纯 Dart，可脱离 Flutter / IO 单测。
library;

import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/answer_sheet.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/region/grading_rules.dart';
import 'package:shuaqi/domain/region/region_rect.dart';

/// 判定「明显改动」的文本相似度阈值。
///
/// 低于这个值视为「答案改了很多」，AI 原判不再可靠，需要按当前 OCR 重判。
/// 取 0.80 是保守值：手写多写一个步骤、改一个数字都可能掉到 0.8 以下；
/// 真机试用后如果发现误触发太多，只改这一处常量。
const double kSignificantAnswerSimilarity = 0.80;

/// 一次 OCR / 判题对应的作答指纹。
///
/// 组成（顺序固定，便于跨设备复现）：
/// - 作答框所在页与矩形；
/// - 该题答题纸张数；
/// - 答题卡每张纸的 `revision / 笔画数 / 点数 / 每笔包围盒`；
/// - 卷面框内笔画的同一组信息（只有答题卡没有笔迹时才参与 OCR，
///   但仍计入指纹：用户可能在卷面上补写）。
///
/// 这里不引入随机 UID（`InkStroke.uid` 解码时会重新生成，跨进程不稳定），
/// 只用几何与计数。
String answerSignatureOf({
  required AnswerSheetEntry entry,
  required List<InkDoc> sheetDocs,
  required int pageRevision,
  required List<InkStroke> pageStrokes,
  required int paperPages,
}) {
  final StringBuffer buffer = StringBuffer()
    ..write('v1|')
    ..write(entry.pageIndex)
    ..write('|')
    ..write(_rectKey(entry.rect))
    ..write('|pp:')
    ..write(paperPages);

  for (int i = 0; i < sheetDocs.length; i += 1) {
    final InkDoc doc = sheetDocs[i];
    buffer
      ..write('|s')
      ..write(i)
      ..write(':')
      ..write(doc.revision)
      ..write(':')
      ..write(doc.strokes.length)
      ..write(':')
      ..write(doc.pointCount);
    _writeStrokeSummary(buffer, doc.strokes);
  }

  buffer
    ..write('|p:')
    ..write(pageRevision)
    ..write(':')
    ..write(pageStrokes.length);
  _writeStrokeSummary(buffer, pageStrokes);

  return _fnv1a32(buffer.toString());
}

/// 判题记录是否有「判题快照」。
///
/// 0.1.3 之前的记录没有这三个字段。不能把「没有快照」当成「答案改过」，
/// 否则升级后第一次改卷会把所有 AI 判过的题重判一遍。没有快照时按保守策略
/// 保留 AI 原判。
bool hasGradeSnapshot(QuestionGrade grade) {
  return grade.judgedSig.isNotEmpty ||
      grade.judgedRefHash.isNotEmpty ||
      grade.judgedText.isNotEmpty;
}

/// 参考答案的稳定哈希（用于发现「答案来源变了」）。
String referenceHashOf(String? reference) {
  final String normalized = normalizeAnswerText(reference ?? '');
  return _fnv1a32('ref|$normalized');
}

/// 当前作答对上一次判题而言是否「有明显改动」。
///
/// - 没有判题快照 → false（保留原判，不冒险重判）；
/// - 参考答案变了 → true；
/// - OCR 文本相似度低于 [kSignificantAnswerSimilarity] → true；
/// - 空 ↔ 非空 → true；
/// - 其它（只改了几个字但整体一致、或只重写了一模一样的答案）→ false。
bool isSignificantAnswerChange({
  required QuestionGrade grade,
  required String currentText,
  required String currentReference,
  String? currentSignature,
}) {
  if (!hasGradeSnapshot(grade)) {
    return false;
  }
  if (grade.judgedRefHash.isNotEmpty &&
      grade.judgedRefHash != referenceHashOf(currentReference)) {
    return true;
  }
  final String before = normalizeAnswerText(grade.judgedText);
  final String after = normalizeAnswerText(currentText);
  if (before.isEmpty && after.isEmpty) {
    // 两边都没有可比较的文本：只能看指纹。
    if (currentSignature != null &&
        grade.judgedSig.isNotEmpty &&
        grade.judgedSig != currentSignature) {
      // 没有文字时无法判断「改了多少」，按有明显改动处理，让上层重判/问 AI。
      return true;
    }
    return false;
  }
  if (before.isEmpty || after.isEmpty) {
    return true;
  }
  if (before == after) {
    return false;
  }
  return answerTextSimilarity(before, after) < kSignificantAnswerSimilarity;
}

/// 两段文本的归一化相似度（0..1）。
///
/// 先走 [normalizeAnswerText]（全角→半角、去空白/前缀/尾标点、小写），
/// 再算 Levenshtein 距离。题作答通常不超过几百字，直接 DP 足够。
double answerTextSimilarity(String a, String b) {
  final String left = normalizeAnswerText(a);
  final String right = normalizeAnswerText(b);
  if (left.isEmpty && right.isEmpty) {
    return 1;
  }
  if (left.isEmpty || right.isEmpty) {
    return 0;
  }
  if (left == right) {
    return 1;
  }
  final int distance = _levenshtein(left, right);
  final int longest = left.length > right.length ? left.length : right.length;
  if (longest == 0) {
    return 1;
  }
  return (1 - distance / longest).clamp(0.0, 1.0).toDouble();
}

int _levenshtein(String a, String b) {
  final int m = a.length;
  final int n = b.length;
  if (m == 0) {
    return n;
  }
  if (n == 0) {
    return m;
  }
  List<int> previous = List<int>.generate(n + 1, (int i) => i);
  List<int> current = List<int>.filled(n + 1, 0);
  for (int i = 1; i <= m; i += 1) {
    current[0] = i;
    for (int j = 1; j <= n; j += 1) {
      final int cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final int deletion = previous[j] + 1;
      final int insertion = current[j - 1] + 1;
      final int substitution = previous[j - 1] + cost;
      int best = deletion < insertion ? deletion : insertion;
      if (substitution < best) {
        best = substitution;
      }
      current[j] = best;
    }
    final List<int> swap = previous;
    previous = current;
    current = swap;
  }
  return previous[n];
}

void _writeStrokeSummary(StringBuffer buffer, List<InkStroke> strokes) {
  for (final InkStroke stroke in strokes) {
    if (stroke.points.isEmpty) {
      buffer.write('|e');
      continue;
    }
    final InkRect bounds = stroke.bounds;
    buffer
      ..write('|')
      ..write(_num(bounds.left))
      ..write(',')
      ..write(_num(bounds.top))
      ..write(',')
      ..write(_num(bounds.width))
      ..write(',')
      ..write(_num(bounds.height))
      ..write(',')
      ..write(stroke.pointCount)
      ..write(',')
      ..write(stroke.style.index);
  }
}

String _rectKey(RegionRect rect) {
  return '${_num(rect.left)},${_num(rect.top)},'
      '${_num(rect.right)},${_num(rect.bottom)}';
}

String _num(double value) => (value * 10).round().toString();

/// 32 位 FNV-1a。只做「是否变化」的短指纹，不做安全哈希。
String _fnv1a32(String input) {
  int hash = 0x811c9dc5;
  for (final int code in input.codeUnits) {
    hash ^= code;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
