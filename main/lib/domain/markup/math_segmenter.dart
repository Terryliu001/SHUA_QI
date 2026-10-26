/// 把一段可能含 LaTeX 的文本切成「普通文本 / 行内公式 / 行间公式」。
///
/// 纯函数，必须单测（开发指南 07 / T6.7）。
///
/// 安全规则（最重要的一条）：
/// **未闭合的定界符 → 余下全文当普通文本**。流式输出到一半时 `$\frac{x^2`
/// 绝不能交给公式渲染器，否则每 80ms 抛一次异常。
library;

/// 一段内容。
sealed class MathSegment {
  const MathSegment();
}

/// 普通文本（原样显示）。
class TextSegment extends MathSegment {
  const TextSegment(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is TextSegment && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'Text(${text.length})';
}

/// 公式段。[tex] **不含定界符**。
class FormulaSegment extends MathSegment {
  const FormulaSegment(this.tex, {this.display = false});

  final String tex;
  final bool display;

  @override
  bool operator ==(Object other) =>
      other is FormulaSegment && other.tex == tex && other.display == display;

  @override
  int get hashCode => Object.hash(tex, display);

  @override
  String toString() => '${display ? 'Display' : 'Inline'}($tex)';
}

/// 切分。
List<MathSegment> segmentMath(String raw) {
  if (raw.isEmpty) {
    return const <MathSegment>[];
  }
  final List<MathSegment> out = <MathSegment>[];
  final StringBuffer text = StringBuffer();
  int i = 0;

  void flushText() {
    if (text.isEmpty) {
      return;
    }
    out.add(TextSegment(text.toString()));
    text.clear();
  }

  void addMath(String tex, {required bool display}) {
    // 空公式（`$$` / `$ $`）没有可渲染内容，按文本保留定界符。
    if (tex.trim().isEmpty) {
      text.write(display ? '\$\$$tex\$\$' : '\$$tex\$');
      return;
    }
    flushText();
    out.add(FormulaSegment(tex, display: display));
  }

  while (i < raw.length) {
    // 1) 代码围栏：整段按文本保留，不解析里面的 $。
    if (raw.startsWith('```', i)) {
      final int end = raw.indexOf('```', i + 3);
      if (end < 0) {
        text.write(raw.substring(i));
        i = raw.length;
        break;
      }
      text.write(raw.substring(i, end + 3));
      i = end + 3;
      continue;
    }
    // 2) 行内代码：只吞同一行内的反引号对。
    if (raw[i] == '`') {
      final int lineEnd = raw.indexOf('\n', i);
      final int end = raw.indexOf('`', i + 1);
      if (end > i && (lineEnd < 0 || end < lineEnd)) {
        text.write(raw.substring(i, end + 1));
        i = end + 1;
        continue;
      }
    }
    // 3) 转义美元：\$ → 字面 $
    if (raw.startsWith(r'\$', i)) {
      text.write(r'$');
      i += 2;
      continue;
    }
    // 4) \( … \) / \[ … \]
    if (raw.startsWith(r'\(', i)) {
      final int end = raw.indexOf(r'\)', i + 2);
      if (end < 0) {
        text.write(raw.substring(i));
        i = raw.length;
        break;
      }
      addMath(raw.substring(i + 2, end), display: false);
      i = end + 2;
      continue;
    }
    if (raw.startsWith(r'\[', i)) {
      final int end = raw.indexOf(r'\]', i + 2);
      if (end < 0) {
        text.write(raw.substring(i));
        i = raw.length;
        break;
      }
      addMath(raw.substring(i + 2, end), display: true);
      i = end + 2;
      continue;
    }
    // 5) $$ … $$（先于单 $ 判断）
    if (raw.startsWith('\$\$', i)) {
      final int end = raw.indexOf('\$\$', i + 2);
      if (end < 0) {
        text.write(raw.substring(i));
        i = raw.length;
        break;
      }
      addMath(raw.substring(i + 2, end), display: true);
      i = end + 2;
      continue;
    }
    // 6) $ … $：只认未转义的闭合符；找不到就余下全文当文本。
    if (raw[i] == r'$') {
      int end = i + 1;
      bool closed = false;
      while (end < raw.length) {
        if (raw[end] == '\\') {
          end += 2;
          continue;
        }
        if (raw[end] == r'$') {
          closed = true;
          break;
        }
        end++;
      }
      if (!closed) {
        text.write(raw.substring(i));
        i = raw.length;
        break;
      }
      addMath(raw.substring(i + 1, end), display: false);
      i = end + 1;
      continue;
    }
    text.write(raw[i]);
    i += 1;
  }
  flushText();
  return out;
}
