import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/main.dart';

void main() {
  testWidgets('基座页能构建并显示标题与自检条目', (WidgetTester tester) async {
    await tester.pumpWidget(const ShuaqiApp());

    expect(find.text('刷起 SHUAQI'), findsOneWidget);
    expect(find.text('T0.1 工程基座 · 自检页'), findsOneWidget);
    expect(find.textContaining('compileSdk 36'), findsOneWidget);
  });
}
