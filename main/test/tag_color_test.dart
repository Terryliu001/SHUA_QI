import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/tag_color.dart';

void main() {
  test('同一个标签永远得到同一个颜色（稳定哈希）', () {
    expect(defaultTagHex('期中'), defaultTagHex('期中'));
    expect(defaultTagHex('错题'), defaultTagHex('错题'));
  });

  test('颜色一定落在色板里', () {
    for (final String tag in <String>['期中', '数学', 'A', '卷', '_tag']) {
      expect(kTagPalette, contains(defaultTagHex(tag)));
    }
  });

  test('空标签退回第一个颜色（不会崩）', () {
    expect(defaultTagHex(''), kTagPalette.first);
  });

  test('不同标签尽量分散（不是全落到一个色）', () {
    final Set<String> used = <String>{
      for (int i = 0; i < 40; i++) defaultTagHex('标签$i'),
    };
    expect(used.length, greaterThan(3));
  });
}
