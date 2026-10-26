import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/region/answer.dart';

/// 一卷的题目集合。`loadBundle` 一次 JOIN 取完，UI 按页取用。
///
/// ## 为什么在 domain 而不是 state（2026-10-24）
///
/// 它只是个**数据容器**（题目列表 + 答案表），不碰 IO、不碰 provider。
/// 之前放在 `state/region_providers.dart`，于是任何要用到它的测试
/// （比如 `test/region_panel_actions_test.dart`）都会顺着 import 链
/// 拖进 `infra/pdf/pdfrx_source.dart` → pdfrx（native assets 包）→
/// 宿主机 `flutter test` 编不过（要编 pdfium 的 gate 库，而沙箱禁 reg.exe）。
///
/// 把它下沉到 domain 之后，这条测试在宿主机就能跑（秒级反馈），
/// 不用为了验证一个纯数据容器去真机上跑 10 分钟的集成测试。
///
/// 数据来源（`regionSetProvider`）仍然留在 state —— 那是 IO，留在 state 对。
class RegionSet {
  const RegionSet(this.questions, {this.answers = AnswerSet.empty});

  final List<QuestionBundle> questions;

  /// 文末答案区抽出的答案（label → 文本）；扫描件/无答案时为空。
  final AnswerSet answers;

  static const RegionSet empty = RegionSet(<QuestionBundle>[]);

  bool get isEmpty => questions.isEmpty;

  int get count => questions.length;

  /// 本页上所有"有区域"的题（跨页题在每页都会出现）。
  List<QuestionBundle> onPage(int pageIndex) => <QuestionBundle>[
    for (final QuestionBundle bundle in questions)
      if (bundle.slices.any(
        (QuestionSlice slice) => slice.pageIndex == pageIndex,
      ))
        bundle,
  ];
}
