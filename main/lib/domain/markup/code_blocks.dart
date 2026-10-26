/// 把 AI 回复切成「文本 / 代码块」——纯函数，可单测。
///
/// 为什么要先切代码块再交给公式渲染：
/// 代码里经常有 `$`（shell、模板字符串、正则），先被公式切分会把代码切烂。
/// 代码块保留原文，文本块才走 `stripLightMarkdown` + `segmentMath`。
///
/// 未闭合的代码围栏按普通文本处理（流式输出到一半时不要闪出一块半截代码）。
library;

sealed class ContentBlock {
  const ContentBlock();
}

class TextBlock extends ContentBlock {
  const TextBlock(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is TextBlock && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

class CodeBlock extends ContentBlock {
  const CodeBlock(this.code, {this.language = ''});

  final String code;
  final String language;

  @override
  bool operator ==(Object other) =>
      other is CodeBlock && other.code == code && other.language == language;

  @override
  int get hashCode => Object.hash(code, language);
}

/// 按行扫描 fenced code block（```lang ... ```）。
///
/// - 只有行首（允许前导空格）的 ``` 才开新块，行内 ``` 不处理；
/// - 结束围栏是一行只有 ```（允许前后空格）；
/// - 未闭合时把开围栏与内容原样留在文本块里。
List<ContentBlock> splitCodeBlocks(String raw) {
  if (raw.isEmpty) {
    return const <ContentBlock>[];
  }
  final List<String> lines = raw.split('\n');
  final List<ContentBlock> blocks = <ContentBlock>[];
  final List<String> textLines = <String>[];
  final List<String> codeLines = <String>[];
  String language = '';
  bool inCode = false;
  String fenceLine = '';

  void flushText() {
    if (textLines.isEmpty) {
      return;
    }
    blocks.add(TextBlock(textLines.join('\n')));
    textLines.clear();
  }

  void flushCode() {
    blocks.add(CodeBlock(codeLines.join('\n'), language: language));
    codeLines.clear();
    language = '';
  }

  for (final String line in lines) {
    final String leftTrimmed = line.trimLeft();
    if (!inCode && leftTrimmed.startsWith('```')) {
      flushText();
      inCode = true;
      fenceLine = line;
      language = leftTrimmed.substring(3).trim();
      continue;
    }
    if (inCode && line.trim() == '```') {
      flushCode();
      inCode = false;
      fenceLine = '';
      continue;
    }
    if (inCode) {
      codeLines.add(line);
    } else {
      textLines.add(line);
    }
  }
  if (inCode) {
    // 未闭合：把开围栏也还原，按文本显示（流式安全）。
    // 能并进上一段文本就并进去，避免渲染时凭空多一个块间距。
    final String unclosed = <String>[fenceLine, ...codeLines].join('\n');
    codeLines.clear();
    if (textLines.isNotEmpty) {
      textLines.add(unclosed);
    } else if (blocks.isNotEmpty && blocks.last is TextBlock) {
      final TextBlock previous = blocks.removeLast() as TextBlock;
      blocks.add(TextBlock('${previous.text}\n$unclosed'));
    } else {
      blocks.add(TextBlock(unclosed));
    }
  }
  flushText();
  return blocks;
}
