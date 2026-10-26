import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/ui/widgets/image_crop_sheet.dart';

void main() {
  test('封面输出比例：1600 宽时高按比例算，不再写死 1600×1600', () {
    const CropKind kind = CropKind.cover(aspectRatio: 5.2);
    expect(kind.outWidth, 1600);
    expect(kind.outputHeight, (1600 / 5.2).round());
  });

  test('头像输出固定 512×512', () {
    const CropKind kind = CropKind.avatar();
    expect(kind.outWidth, 512);
    expect(kind.outputHeight, 512);
  });
}
