/// 题型 → 中文短标签（纯 Dart）。
///
/// 原来只存在于 `ui/favorites/favorite_card.dart`（收藏夹卡片用），
/// 记录页的题目卡、词云的「按题型」维度也要同一份文案。挪到 domain 是为了
/// 让**同一道题在收藏夹与时间线里叫同一个名字**，而不是各写一遍 switch。
library;

String questionKindLabel(String kind) => switch (kind) {
  'choice' => '选择题',
  'judge' => '判断题',
  'blank' => '填空题',
  'essay' => '解答题',
  _ => '题目',
};

/// 词云/统计里的兜底名（`unknown` 不该显示成"题目"以外的怪词）。
String questionKindCloudLabel(String kind) =>
    kind == 'unknown' || kind.isEmpty ? '未分类题型' : questionKindLabel(kind);

/// 题号的可读形式：`5.` → `5`，`（3）` 保持括号，空串回落 `—`。
///
/// 切题出来的 `label` 是**卷面原文**（常带句点/顿号），直接拼成"第 5. 题"
/// 会多一个句号。展示层统一过这个函数，数据层不动原文（回原卷定位还要用它）。
String questionLabelText(String label) {
  String text = label.trim();
  while (text.isNotEmpty) {
    final String last = text.substring(text.length - 1);
    if (last == '.' || last == '。' || last == '、' || last == ' ') {
      text = text.substring(0, text.length - 1);
      continue;
    }
    break;
  }
  return text.isEmpty ? '—' : text;
}
