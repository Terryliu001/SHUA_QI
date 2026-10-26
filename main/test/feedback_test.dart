import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/feedback/feedback.dart';

/// 用户反馈表单的校验（2026-10-26 用户第 2 条：先做界面、留好接口）。
///
/// ## 口径
/// - 正文太短没法定位问题 → 拦；
/// - 手机号**选填**，填了就必须是 11 位（用户要"修复后短信回复"）；
/// - 图片最多 3 张、单张 ≤6MB（再大就该压了）。
void main() {
  test('正文太短或太长都要拦', () {
    expect(validateFeedbackText('太短'), isNotNull);
    expect(validateFeedbackText('够长的一句话描述'), isNull);
    expect(
      validateFeedbackText('啊' * (kMaxFeedbackTextLength + 1)),
      isNotNull,
    );
    expect(
      validateFeedbackText('啊' * kMaxFeedbackTextLength),
      isNull,
      reason: '正好到上限应当放行',
    );
  });

  test('手机号选填：空串合法，非空必须 11 位', () {
    expect(validateFeedbackPhone(''), isNull);
    expect(validateFeedbackPhone('   '), isNull);
    expect(validateFeedbackPhone('13800138000'), isNull);
    expect(validateFeedbackPhone('12345'), isNotNull);
    expect(validateFeedbackPhone('23800138000'), isNotNull);
    expect(validateFeedbackPhone('1380013800a'), isNotNull);
  });

  test('图片数量与大小都要拦', () {
    final Uint8List small = Uint8List(16);
    expect(validateFeedbackImages(<Uint8List>[small]), isNull);
    expect(
      validateFeedbackImages(<Uint8List>[small, small, small, small]),
      isNotNull,
      reason: '超过 3 张要拦',
    );
    expect(validateFeedbackImages(<Uint8List>[Uint8List(0)]), isNotNull);
    expect(
      validateFeedbackImages(<Uint8List>[
        Uint8List(kMaxFeedbackImageBytes + 1),
      ]),
      isNotNull,
    );
  });

  test('反馈类型能按名字解码，未知值回落到 bug', () {
    expect(FeedbackKind.decode('idea'), FeedbackKind.idea);
    expect(FeedbackKind.decode('nope'), FeedbackKind.bug);
    for (final FeedbackKind kind in FeedbackKind.values) {
      expect(kind.label, isNotEmpty);
      expect(kind.hint, isNotEmpty);
    }
  });

  test('草稿的元数据不夹带图片字节', () {
    final FeedbackDraft draft = FeedbackDraft(
      kind: FeedbackKind.bug,
      text: '  第 3 页的框拖不动  ',
      phone: ' 13800138000 ',
      images: <Uint8List>[Uint8List.fromList(<int>[1, 2, 3])],
    );
    final Map<String, Object?> json = draft.toJson(imageFiles: <String>['a.img']);
    expect(json['text'], '第 3 页的框拖不动');
    expect(json['phone'], '13800138000');
    expect(json['images'], <String>['a.img']);
    expect(json.containsKey('images'), isTrue);
  });
}
