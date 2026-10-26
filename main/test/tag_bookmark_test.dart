import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/ui/bookshelf/tag_bookmark.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

/// 标签书签的形状与竖排（2026-10-24 第二轮：圆角避让）。
///
/// 钉两件会被改坏的事：
/// 1. 书签顶部必须有圆角 —— 直角尖戳出卡片 20dp 圆角的弧线之外，
///    就是用户说的"圆角没处理好"；
/// 2. 竖排按 **runes** 拆字 —— 用 `split('')` 会把 emoji 劈成两半。
void main() {
  test('竖排 = 一个字一行', () {
    expect(TagBookmark.verticalText('解析几何'), '解\n析\n几\n何');
    expect(TagBookmark.verticalText('A'), 'A');
    expect(TagBookmark.verticalText(''), '');
  });

  test('竖排按 runes 拆：emoji 不被劈开', () {
    // '😀' 是一个代理对，`split('')` 会把它切成两个孤立的 surrogate。
    final String vertical = TagBookmark.verticalText('A\u{1F600}');
    expect(vertical.split('\n'), <String>['A', '\u{1F600}']);
  });

  test('书签顶部两角是圆的：角上的点不在形状内', () {
    const BookmarkClipper clipper = BookmarkClipper();
    const Size size = Size(40, 22);
    final Path path = clipper.getClip(size);

    // 左上角 (0.5, 0.5)：直角时属于形状，圆角（r=6）时被切掉。
    expect(path.contains(const Offset(0.5, 0.5)), isFalse);
    // 右上角同理。
    expect(path.contains(const Offset(39.5, 0.5)), isFalse);
    // 底边仍是直的（V 形缺口只在正中）：左下角在内。
    expect(path.contains(const Offset(0.5, 21)), isTrue);
    // 中间当然在内。
    expect(path.contains(const Offset(20, 6)), isTrue);
    // 底部正中被 V 形缺口挖掉。
    expect(path.contains(const Offset(20, 21.5)), isFalse);
  });

  testWidgets('竖排书签渲染成多行，横排是一行', (WidgetTester tester) async {
    Color colorOf(String _) => const Color(0xFF1F6FEB);
    await tester.pumpWidget(
      MaterialApp(
        theme: ShqTheme.light(),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              TagBookmarks(
                tags: const <String>['解析几何'],
                colorOf: colorOf,
                vertical: true,
              ),
              TagBookmarks(
                tags: const <String>['解析几何'],
                colorOf: colorOf,
              ),
            ],
          ),
        ),
      ),
    );
    final List<Text> texts = tester
        .widgetList<Text>(find.byType(Text))
        .toList(growable: false);
    expect(texts.length, 2);
    expect(texts.first.data, '解\n析\n几\n何');
    expect(texts.first.maxLines, kBookmarkVerticalLines);
    expect(texts.last.data, '解析几何');
    expect(texts.last.maxLines, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有标签时书签不占位', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ShqTheme.light(),
        home: const Scaffold(
          body: TagBookmarks(
            tags: <String>[],
            colorOf: _unused,
          ),
        ),
      ),
    );
    // 不画任何书签 —— 卡片的尺寸/圆角不能因为有没有标签而变化。
    expect(find.byType(TagBookmark), findsNothing);
  });
}

Color _unused(String _) => const Color(0xFF1F6FEB);
