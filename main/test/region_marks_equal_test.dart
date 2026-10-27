import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/ui/reader/region_overlay.dart';

/// 叠加层重绘判定（2026-10-27 用户：确认虚线框后没有立刻变实线）。
///
/// 只改 `level`（1 → 2，虚线 → 实线）时，key / 矩形 / 题号 / 置信度都可能没变。
/// 如果比较里漏了 `level`，`shouldRepaint` 就会判"没变"，屏幕停在旧图 ——
/// 这正是用户看到的现象。这里把"哪些字段变了必须重绘"钉住。
void main() {
  RegionMark mark({
    int level = 2,
    double confidence = 0.9,
    String grade = 'green',
    String label = '八、',
    bool locked = false,
  }) => RegionMark(
    key: '八、|1|500',
    pageIndex: 1,
    rect: RegionRect.fromLTRB(50, 500, 400, 620),
    label: label,
    grade: grade,
    confidence: confidence,
    level: level,
    locked: locked,
  );

  test('只把 level 从 1 改成 2 → 必须重绘（虚线变实线）', () {
    expect(
      regionMarksEqual(
        <RegionMark>[mark(level: 1)],
        <RegionMark>[mark(level: 2)],
      ),
      isFalse,
    );
  });

  test('完全一样 → 不重绘', () {
    expect(
      regionMarksEqual(<RegionMark>[mark()], <RegionMark>[mark()]),
      isTrue,
    );
  });

  test('置信度 / 题号 / 锁定 / 数量变化都要重绘', () {
    expect(
      regionMarksEqual(
        <RegionMark>[mark(confidence: 0.9)],
        <RegionMark>[mark(confidence: 0.4, grade: 'yellow')],
      ),
      isFalse,
    );
    expect(
      regionMarksEqual(
        <RegionMark>[mark(label: '八、')],
        <RegionMark>[mark(label: '9.')],
      ),
      isFalse,
    );
    expect(
      regionMarksEqual(
        <RegionMark>[mark(locked: false)],
        <RegionMark>[mark(locked: true)],
      ),
      isFalse,
    );
    expect(
      regionMarksEqual(<RegionMark>[mark()], <RegionMark>[mark(), mark()]),
      isFalse,
    );
  });
}
