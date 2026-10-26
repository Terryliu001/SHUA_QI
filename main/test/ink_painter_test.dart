import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/ui/reader/ink_painters.dart';

/// 换纸后已提交墨迹必须重绘（2026-10-24 真机发现）。
///
/// 现象：原图写下的黑笔迹，切到夜读后仍是深色，在暖黑纸上几乎看不见。
/// 根因：`CommittedInkCache.sync` 会按新纸色重建 ribbon，但画布的
/// `shouldRepaint` 只比较 doc/scale，判定"不用重绘"。
void main() {
  test('darkPaper 变化必须触发已提交墨迹层重绘', () {
    final CommittedInkCache cache = CommittedInkCache();
    final CommittedInkPainter light = CommittedInkPainter(
      cache: cache,
      doc: InkDoc.empty,
      scale: 1,
      darkPaper: false,
    );
    final CommittedInkPainter night = CommittedInkPainter(
      cache: cache,
      doc: InkDoc.empty,
      scale: 1,
      darkPaper: true,
    );

    expect(night.shouldRepaint(light), isTrue);
    expect(light.shouldRepaint(night), isTrue);
    // 同纸同 doc 同 scale：不重绘（避免每帧无谓重放）。
    expect(light.shouldRepaint(light), isFalse);
  });
}
