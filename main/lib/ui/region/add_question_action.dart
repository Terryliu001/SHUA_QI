import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/region_set.dart';
import 'package:shuaqi/domain/region/correction.dart';

/// 「加题」到底该落哪条 correction（2026-10-27 用户反馈后定稿）。
///
/// 两种语义，按框的 `level` 分：
///
/// - **虚线框（level ≤ 1）**：切题没拿准的块 —— 可能是大题容器，也可能就是
///   一道题。用户点「加题」的意思是"**这一块就是这道题**"，所以落
///   [ConfirmQuestionCorrection]：**就地确认**，题号 / 序号 / 区域 / 题目 id
///   全都不变，只把虚线变成实线。
/// - **实线题（level ≥ 2）**：在本题下方**新增**一道题（题号接现有最大号 +1），
///   用于"切题把两道题并成一条"时从中间加一道回去。
///
/// 为什么抽成纯函数：这个分支以前是反的（虚线框也走"新增 + 删除原框"），
/// 结果题号被改成"最大号 +1"、在题目面板里也跳到列表末尾。语义写进一个
/// 可单测的函数里，比散在页面 `_applyAction` 的 if 里更难改坏。
RegionCorrection addQuestionFor({
  required QuestionBundle bundle,
  required RegionSet set,
  required String id,
  required String key,
}) {
  if (bundle.question.level <= 1) {
    return ConfirmQuestionCorrection(id: id, key: key);
  }
  final QuestionSlice base = bundle.slices.last;
  return AddQuestionCorrection(
    id: id,
    key: '',
    label: nextQuestionLabel(set),
    rect: base.rect,
    page: base.pageIndex,
  );
}

/// 下一个默认题号：现有最大数字 +1（扫描件认不出题号时也给一个能用的值）。
String nextQuestionLabel(RegionSet set) {
  int max = 0;
  for (final QuestionBundle bundle in set.questions) {
    final Match? match = RegExp(r'\d+').firstMatch(bundle.question.label ?? '');
    final int? number = match == null ? null : int.tryParse(match.group(0)!);
    if (number != null && number > max) {
      max = number;
    }
  }
  return '${max + 1}.';
}
