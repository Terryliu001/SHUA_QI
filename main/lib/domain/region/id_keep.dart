/// 重算时保住 `question.id`（纯 Dart，可单测）。
///
/// ## 为什么必须保住
/// 每次改框都走"整卷重算"。原先的实现给每道题都发一个新 ULID，于是**同一道题
/// 每次编辑都换身份**——这对第 5 周的"笔迹归属到题"和识别结果 `text_block.question_id`
/// 是致命的：用户拖一下框，之前的归属和识别结果就全部指向一条已经不存在的记录。
///
/// 所以重算时先按 anchor 把这题原来的 id 找回来：
/// 1. **精确**：`题号|页|y` 完全一致（没动过的题，占绝大多数）；
/// 2. **模糊**：同题号、同页、y 差 ≤ [defaultTolerance]（拖动/缩放会让 key 里的 y 变）；
/// 3. 都对不上 → 发新 id（真新题：手画、拆分出来的下段）。
///
/// 一个旧 id 只允许被认领一次，避免拆分出来的上下两段抢同一个身份。
library;

import 'package:shuaqi/domain/region/edited_question.dart';

/// 模糊匹配的 y 容差（pt）。与覆盖层 anchor 的退化匹配保持一致。
const double defaultTolerance = 80;

/// 返回与 [newKeys] **等长**的 id 列表；认领不到旧 id 的位置为 null。
///
/// [oldIdByKey] 是上一轮落库结果（anchor → question.id）。
List<String?> matchExistingQuestionIds({
  required Map<String, String> oldIdByKey,
  required List<String> newKeys,
  double tolerance = defaultTolerance,
}) {
  final List<String?> result = List<String?>.filled(newKeys.length, null);
  if (oldIdByKey.isEmpty || newKeys.isEmpty) {
    return result;
  }
  final Set<String> used = <String>{};

  // 1) 精确命中
  for (int i = 0; i < newKeys.length; i++) {
    final String? id = oldIdByKey[newKeys[i]];
    if (id != null && used.add(id)) {
      result[i] = id;
    }
  }

  // 2) 模糊命中：同题号 + 同页 + 最近
  final List<MapEntry<String, String>> olds = oldIdByKey.entries
      .where((MapEntry<String, String> entry) => !used.contains(entry.value))
      .toList(growable: false);
  for (int i = 0; i < newKeys.length; i++) {
    if (result[i] != null) {
      continue;
    }
    final String label = normalizeLabel(anchorLabel(newKeys[i]));
    final int page = anchorPage(newKeys[i]);
    final double y = anchorY(newKeys[i]);
    String? bestId;
    double bestDistance = double.infinity;
    for (final MapEntry<String, String> entry in olds) {
      if (used.contains(entry.value)) {
        continue;
      }
      if (normalizeLabel(anchorLabel(entry.key)) != label) {
        continue;
      }
      if (anchorPage(entry.key) != page) {
        continue;
      }
      final double distance = (anchorY(entry.key) - y).abs();
      if (distance <= tolerance && distance < bestDistance) {
        bestDistance = distance;
        bestId = entry.value;
      }
    }
    if (bestId != null && used.add(bestId)) {
      result[i] = bestId;
    }
  }
  return result;
}
