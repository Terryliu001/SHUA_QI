import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';

/// 答题卡纸张配置的落盘（`layout/answer_paper.v1.json`）。
///
/// 是**用户产物**：重切题、换 cutter 都要保留（和作答框、判题结论同级）。
class AnswerPaperStore {
  const AnswerPaperStore(this._layout);

  final LayoutStore _layout;

  Future<AnswerPaperData> load(String workbookId) async {
    try {
      return AnswerPaperData.fromJson(
        await _layout.readAnswerPaper(workbookId),
      );
    } on Object {
      return AnswerPaperData.empty;
    }
  }

  Future<void> save(String workbookId, AnswerPaperData data) =>
      _layout.writeAnswerPaper(workbookId, data.toJson());
}
