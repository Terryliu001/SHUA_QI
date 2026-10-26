import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/markup/code_blocks.dart';

void main() {
  test('纯文本只有一段 TextBlock', () {
    expect(splitCodeBlocks('你好'), <ContentBlock>[const TextBlock('你好')]);
  });

  test('fenced 代码块带语言，内容原样保留（含 \$）', () {
    const String raw = '前\n```dart\nfinal x = r"\$y";\n```\n后';
    final List<ContentBlock> blocks = splitCodeBlocks(raw);
    expect(blocks.length, 3);
    expect(blocks[0], const TextBlock('前'));
    expect(blocks[1], const CodeBlock('final x = r"\$y";', language: 'dart'));
    expect(blocks[2], const TextBlock('后'));
  });

  test('多个代码块', () {
    final List<ContentBlock> blocks = splitCodeBlocks(
      'a\n```\none\n```\nb\n```json\n{"x":1}\n```',
    );
    expect(blocks.length, 4);
    expect(blocks[1], const CodeBlock('one'));
    expect(blocks[3], const CodeBlock('{"x":1}', language: 'json'));
  });

  test('未闭合围栏按文本保留，流式不闪半截代码', () {
    final List<ContentBlock> blocks = splitCodeBlocks(
      '看：\n```dart\nfinal x = 1;',
    );
    expect(blocks.length, 1);
    expect(blocks.single, isA<TextBlock>());
    expect((blocks.single as TextBlock).text, contains('看：'));
    expect((blocks.single as TextBlock).text, contains('```dart'));
    expect((blocks.single as TextBlock).text, contains('final x = 1;'));
  });

  test('行内 ``` 不开代码块', () {
    final List<ContentBlock> blocks = splitCodeBlocks('行内 ```x``` 不算块');
    expect(blocks.single, isA<TextBlock>());
  });

  test('空字符串没有块', () {
    expect(splitCodeBlocks(''), isEmpty);
  });
}
