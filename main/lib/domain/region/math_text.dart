/// 公式文本的**显示层**归一化（纯 Dart，可单测）。
///
/// ## 为什么需要它
///
/// PDF 文本层里的公式不是 LaTeX，而是"Unicode 数学字符 + 按字形排的碎片"：
///
/// ```text
/// 1.设𝑓(𝑥)={ 1,|𝑥|≤1 ，则𝑓(𝑓(𝑥))=． 0,|𝑥|>1
/// ```
///
/// - `𝑓`/`𝑥`（U+1D400–U+1D7FF，Mathematical Alphanumeric Symbols）在多数
///   Android 系统字体里没有字形，Flutter 直接画成"豆腐块"；
/// - `≤` `∞` `√` `′` 也经常缺字形；
/// - 这些字符对 AI/检索有价值，**不能从入库数据里删掉**。
///
/// 所以分两层：
/// - **入库/喂 AI**：保留原始 Unicode（`question.stem_text` 不动）；
/// - **界面显示**：用 [mathForDisplay] 把数学字符折成 ASCII/常见符号，
///   保证右侧面板能读。
///
/// 这不是"公式排版"：真正的 LaTeX 渲染需要识别出公式结构（引擎 C / AI），
/// 当前只做"可读的纯文本预览"，不引入任何依赖。
library;

/// 这段文本是否"公式/符号密度高到不适合纯文本显示"。
///
/// 2026-10-23 用户口径：数学等符号多的学科，如果做不到公式正确显示，
/// 右侧就**不显示文字**，只给 PDF 题面预览；提交给 AI 时以图片为准。
///
/// 判定刻意保守：
/// - 出现 PDF 私有区（PUA）或数学字母/常见数学符号 → 直接算；
/// - 纯中文/普通英文里的 `x=1` 不会仅因为一个等号被误判。
bool formulaHeavyText(String raw) {
  if (raw.isEmpty) {
    return false;
  }
  int mathSignals = 0;
  int visible = 0;
  for (final int code in raw.runes) {
    if (_isIgnorable(code)) {
      continue;
    }
    visible++;
    if (_isMathCode(code)) {
      mathSignals++;
    }
  }
  if (visible == 0) {
    return false;
  }
  // 两个以上明确数学字符，或数学字符占比 > 6%，就算公式/符号题。
  return mathSignals >= 2 || mathSignals / visible > 0.06;
}

bool _isIgnorable(int code) =>
    code == 0x20 ||
    code == 0x09 ||
    code == 0x0A ||
    code == 0x0D ||
    (code >= 0x200B && code <= 0x200F) ||
    (code >= 0x2060 && code <= 0x206F);

bool _isMathCode(int code) {
  if (code >= 0x1D400 && code <= 0x1D7FF) {
    return true;
  }
  if (code >= 0xE000 && code <= 0xF8FF) {
    return true;
  }
  if (code >= 0x0370 && code <= 0x03FF) {
    return true; // Greek
  }
  return _symbols.containsKey(code) && code != 0x2026 && code != 0x2013;
}

/// 把一段含数学 Unicode 的文本转成可显示的近似文本。
///
/// 只改数学字符与零宽字符；中文、ASCII、全角标点原样保留。
String mathForDisplay(String raw) {
  if (raw.isEmpty) {
    return raw;
  }
  final StringBuffer out = StringBuffer();
  for (final int rune in raw.runes) {
    final String? mapped = _mapRune(rune);
    if (mapped != null) {
      out.write(mapped);
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// Mathematical Alphanumeric Symbols 的拉丁字母块起点（每块 52 个：A-Z + a-z）。
const List<int> _latinMathStarts = <int>[
  0x1D400, // bold
  0x1D434, // italic
  0x1D468, // bold italic
  0x1D49C, // script
  0x1D4D0, // bold script
  0x1D504, // fraktur
  0x1D538, // double-struck
  0x1D56C, // bold fraktur
  0x1D5A0, // sans-serif
  0x1D5D4, // bold sans-serif
  0x1D608, // italic sans-serif
  0x1D63C, // bold italic sans-serif
  0x1D670, // monospace
];

String? _mapRune(int code) {
  // 零宽字符/软连字符：直接去掉，避免面板出现空白方框。
  if (code == 0x200B ||
      code == 0x200C ||
      code == 0x200D ||
      code == 0x2060 ||
      code == 0xFEFF ||
      code == 0x00AD) {
    return '';
  }
  if (code == 0x00A0) {
    return ' ';
  }

  // **PDF 私有区字形**（U+E000–U+F8FF）。
  //
  // 数学卷的嵌入字体（Cambria Math / Symbol 子集）里，括号、无穷、大于号
  // 等常常被 pdfium 报成 PUA 码位（真卷：`\uF0A5`=∞、`\uF03E`=>、
  // `\uF03C`=<、`\uF0B9`=≠、`\uF0ED`={、`\uF0E9..F0FB`=大括号的上下片段）。
  // 没有原字体的 cmap，认不出的一律丢掉——**宁可少一个括号，也不要豆腐块**。
  if (code >= 0xE000 && code <= 0xF8FF) {
    return _puaSymbols[code] ?? '';
  }

  // 数学拉丁字母（粗体/斜体/手写体/双线体/无衬线/等宽）。
  for (final int start in _latinMathStarts) {
    if (code >= start && code < start + 52) {
      final int offset = code - start;
      return String.fromCharCode(
        offset < 26 ? 0x41 + offset : 0x61 + offset - 26,
      );
    }
  }

  // 数学数字：5 块（粗/双线/无衬线/无衬线粗/等宽），每块 0–9。
  if (code >= 0x1D7CE && code <= 0x1D7FF) {
    return String.fromCharCode(0x30 + (code - 0x1D7CE) % 10);
  }

  // 数学希腊字母：映射回普通希腊字母（系统字体通常有 α/β/π 等）。
  if (code >= 0x1D6A8 && code <= 0x1D6C0) {
    return String.fromCharCode(0x0391 + code - 0x1D6A8);
  }
  if (code >= 0x1D6C2 && code <= 0x1D6DA) {
    return String.fromCharCode(0x03B1 + code - 0x1D6C2);
  }
  if (code == 0x1D6C1) {
    return ' grad ';
  }
  if (code == 0x1D6DB) {
    return 'd';
  }

  return _symbols[code];
}

/// PDF 私有区里**能确认含义**的几个码位（真卷实测）。
///
/// 认不出的 PUA 一律返回 null → 上层丢掉；这条策略比"猜一个字符"安全：
/// 猜错会改变公式语义，丢掉只是少一个装饰性括号。
const Map<int, String> _puaSymbols = <int, String>{
  0xF02D: '-',
  0xF03C: '<',
  0xF03E: '>',
  0xF0A2: "'", // prime
  0xF0A5: ' inf ', // ∞
  0xF0B9: '!=', // ≠
  0xF07B: '{',
  0xF07D: '}',
  0xF0ED: '{', // piecewise 左花括号
};

/// 常见数学符号 → 可显示的 ASCII/中文字形（带空格的是"词形"运算符）。
const Map<int, String> _symbols = <int, String>{
  0x2212: '-', // minus
  0x2010: '-',
  0x2011: '-',
  0x2012: '-',
  0x2013: '-',
  0x2014: '-',
  0x2015: '-',
  0x2044: '/', // fraction slash
  0x2215: '/',
  0x2216: '\\',
  0x00D7: '*', // ×
  0x22C5: '*', // ⋅
  0x00B7: '*', // ·
  0x00F7: '/', // ÷
  0x2264: '<=', // ≤
  0x2265: '>=', // ≥
  0x2260: '!=', // ≠
  0x2248: '~=', // ≈
  0x2261: '===', // ≡
  0x2262: '!==', // ≢
  0x221D: ' prop ', // ∝
  0x2032: "'", // ′
  0x2033: "''", // ″
  0x2034: "'''",
  0x2192: '->', // →
  0x2190: '<-', // ←
  0x2194: '<->', // ↔
  0x21D2: '=>', // ⇒
  0x21D4: '<=>', // ⇔
  0x21A6: '|->', // ↦
  0x2200: ' forall ', // ∀
  0x2203: ' exists ', // ∃
  0x2205: ' empty ', // ∅
  0x00AC: ' not ', // ¬
  0x2227: ' and ', // ∧
  0x2228: ' or ', // ∨
  0x2208: ' in ', // ∈
  0x2209: ' notin ', // ∉
  0x220B: ' ni ', // ∋
  0x222A: ' union ', // ∪
  0x2229: ' inter ', // ∩
  0x2282: ' subset ', // ⊂
  0x2286: ' subseteq ', // ⊆
  0x2283: ' supset ', // ⊃
  0x2287: ' supseteq ', // ⊇
  0x2288: ' nsubseteq ',
  0x2289: ' nsupseteq ',
  0x2211: ' sum ', // ∑
  0x220F: ' prod ', // ∏
  0x222B: ' int ', // ∫
  0x222C: ' iint ',
  0x222D: ' iiint ',
  0x222E: ' oint ',
  0x2202: 'd', // ∂
  0x2207: ' grad ', // ∇
  0x221E: ' inf ', // ∞
  0x221A: ' sqrt ', // √
  0x00B1: '+-', // ±
  0x2213: '-+', // ∓
  0x00B0: ' deg ', // °
  0x2220: ' angle ', // ∠
  0x22A5: ' perp ', // ⊥
  0x2225: ' parallel ', // ∥
  0x230A: 'floor(', // ⌊
  0x230B: ')', // ⌋
  0x2308: 'ceil(', // ⌈
  0x2309: ')', // ⌉
  0x27E8: '<', // ⟨
  0x27E9: '>', // ⟩
  0x2329: '<',
  0x232A: '>',
  0x25B3: 'triangle', // △
  0x25A1: 'square', // □
  0x2026: '...', // …
  0x22EF: '...', // ⋯
  0x22EE: '...', // ⋮
  0x00B2: '^2',
  0x00B3: '^3',
  0x00B9: '^1',
  0x2070: '^0',
  0x2074: '^4',
  0x2075: '^5',
  0x2076: '^6',
  0x2077: '^7',
  0x2078: '^8',
  0x2079: '^9',
  0x2080: '_0',
  0x2081: '_1',
  0x2082: '_2',
  0x2083: '_3',
  0x2084: '_4',
  0x2085: '_5',
  0x2086: '_6',
  0x2087: '_7',
  0x2088: '_8',
  0x2089: '_9',
  0x2102: 'C', // ℂ
  0x211D: 'R', // ℝ
  0x2115: 'N', // ℕ
  0x211A: 'Q', // ℚ
  0x2124: 'Z', // ℤ
  0x2111: ' Im ', // ℑ
  0x211C: ' Re ', // ℜ
  0x2135: ' aleph ', // ℵ
  0x2020: '+', // †
  0x2021: '+', // ‡
  0xFFFD: '?', // replacement char
};
