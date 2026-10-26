import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/import_batch.dart';

/// 批量导入的汇总文案（纯函数，宿主机秒级）。
///
/// 覆盖点：三种结局（成功 / 已存在 / 失败）怎么合并成一句话，
/// 以及失败太多时只列前 3 条（否则提示条会撑成一面墙）。
void main() {
  ImportBatchResult result({
    int succeeded = 0,
    int deduped = 0,
    List<String> failures = const <String>[],
  }) {
    return ImportBatchResult(
      imported: <ImportedWorkbook>[
        for (int i = 0; i < succeeded; i++)
          ImportedWorkbook(title: '卷$i', pageCount: 4, thumbCount: 2),
      ],
      deduplicated: <String>[for (int i = 0; i < deduped; i++) '重复$i'],
      failures: failures,
    );
  }

  test('全成功：只说导入了几份', () {
    expect(importSummaryMessage(result(succeeded: 3)), '导入 3 份。');
  });

  test('有重复：重复不是错误，单独说清楚', () {
    expect(
      importSummaryMessage(result(succeeded: 2, deduped: 1)),
      '导入 2 份 · 1 份已存在。',
    );
  });

  test('有失败：报份数并列出文件名', () {
    final String message = importSummaryMessage(
      result(succeeded: 1, failures: <String>['加密卷：文件已加密']),
    );
    expect(message, contains('1 份失败'));
    expect(message, contains('· 加密卷：文件已加密'));
  });

  test('失败超过 3 条：只列前 3 条 + 剩余计数', () {
    final String message = importSummaryMessage(
      result(
        failures: <String>['a：原因', 'b：原因', 'c：原因', 'd：原因', 'e：原因'],
      ),
    );
    expect(message, contains('5 份失败'));
    expect(message, contains('· a：原因'));
    expect(message, contains('· c：原因'));
    expect(message, isNot(contains('· d：原因')));
    expect(message, contains('另有 2 份失败'));
  });

  test('一份都没导入：给兜底文案而不是空白', () {
    expect(importSummaryMessage(result()), '没有导入任何文件');
  });

  test('total 统计三类结局的总数', () {
    expect(result(succeeded: 2, deduped: 1).total, 3);
    expect(result(succeeded: 2, failures: <String>['x：y']).total, 3);
    expect(result().total, 0);
  });
}
