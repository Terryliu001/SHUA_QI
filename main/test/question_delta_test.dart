import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/correction.dart';
import 'package:shuaqi/domain/region/region_rect.dart';

/// 「手改让题目净增减几道」（2026-10-24 A3）。
///
/// 用户口径：面板上要显示的是"增减几道题"，不是操作步数。
/// 所以只有真正改题数的四个操作参与计数，移动/缩放/跨页/改名/锁定一概不计。
void main() {
  const RegionRect rect = RegionRect(left: 0, top: 0, width: 100, height: 40);
  const SplitCorrection split = SplitCorrection(
    id: 'split',
    key: 'k',
    page: 0,
    atY: 200,
  );
  const DeleteCorrection remove = DeleteCorrection(id: 'del', key: 'k');
  const MergeCorrection merge = MergeCorrection(
    id: 'merge',
    key: 'k',
    fromKey: 'k2',
  );

  AddQuestionCorrection add(String id) => AddQuestionCorrection(
    id: id,
    key: 'k$id',
    label: '$id.',
    rect: rect,
    page: 0,
  );

  test('空日志 = 0', () {
    expect(questionDeltaOf(CorrectionLog.empty), 0);
  });

  test('新增 / 切开 +1，删除 / 并入 −1', () {
    expect(questionDeltaOf(CorrectionLog(<RegionCorrection>[add('1')])), 1);
    expect(questionDeltaOf(const CorrectionLog(<RegionCorrection>[split])), 1);
    expect(questionDeltaOf(const CorrectionLog(<RegionCorrection>[remove])), -1);
    expect(questionDeltaOf(const CorrectionLog(<RegionCorrection>[merge])), -1);
  });

  test('不改题数的操作一律不计', () {
    const CorrectionLog log = CorrectionLog(<RegionCorrection>[
      MoveCorrection(id: '5', key: 'k', page: 0, dx: 3, dy: 4),
      ResizeCorrection(id: '6', key: 'k', page: 0, rect: rect),
      LockCorrection(id: '7', key: 'k', value: true),
      RenameCorrection(id: '8', key: 'k', label: '7.'),
    ]);
    expect(questionDeltaOf(log), 0);
  });

  test('混合操作按净额累计', () {
    final CorrectionLog log = CorrectionLog(<RegionCorrection>[
      add('1'),
      add('2'),
      remove,
      merge,
    ]);
    expect(questionDeltaOf(log), 0, reason: '+1 +1 -1 -1 = 0');
  });
}
