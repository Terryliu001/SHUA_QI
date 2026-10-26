import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

/// 第 3 周 T3.1 前置取材 spike：**把真卷的文本层原样倒出来**。
///
/// 为什么必须先做这一步：规格里的切题规则（题号正则、字号跳变、双栏检测）
/// 全部建立在"文本片段长什么样"的假设上，而 T0.4 已经证明 pdfrx 的片段
/// **很碎**（`12.` 会拆成 `1` `2` `.`，还有零宽片段）。不先量一次就写聚类，
/// 等于拿假设当数据。
///
/// 产出（都落在应用自己的外部 files 目录，adb 可直接 pull）：
/// - `text_probe.json`：每页 pageSize + 每个片段的原始 bounds 与页面坐标
/// - 屏幕上：页数、片段数、按 y 聚行的前若干行 —— 用来判断"行聚类阈值"该取多少
///
/// 用法：
///   adb push demo_assets/math_analysis_midterm.pdf \
///     /sdcard/Android/data/com.shuaqi.shuaqi/files/text_probe.pdf
///   flutter run --profile -t spikes/pdf_text_spike/main.dart -d <设备>
///   adb exec-out run-as com.shuaqi.shuaqi cat ... （或直接 pull 外部目录）
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  runApp(const _ProbeApp());
}

const String _outName = 'text_probe.json';
const String _inName = 'text_probe.pdf';

/// 批量模式的匹配前缀：只要 files/ 目录下出现 `eval-*.pdf`，就每份各倒一份
/// `<名字>.json`。这是 T3.2 评测语料（`tool/make_test_papers.py`）的采集入口。
///
/// 为什么不放子目录：`adb shell mkdir` 建的目录 App **列不出来**
/// （Permission denied, errno 13，OPPO/Android 16 实测）。放 App 自己的
/// files 根目录（应用创建、属主是自己）就没这个问题。
const String _batchPrefix = 'eval-';

/// 注意：**不要写死 `/sdcard/...`**。真机上 App 走 `/sdcard` 这个软链会 stat 不到
/// （实测 2026-10-23：adb push 到 `/sdcard/Android/data/<pkg>/files/` 后，应用侧
/// `File.existsSync()` 仍为 false）。必须用 path_provider 拿到的真实外部目录。

class _ProbeApp extends StatelessWidget {
  const _ProbeApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1F6FEB), useMaterial3: true),
      home: const _ProbePage(),
    );
  }
}

class _ProbePage extends StatefulWidget {
  const _ProbePage();

  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage> {
  final List<String> _log = <String>[];
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _say(String line) {
    debugPrint('[probe] $line');
    if (!mounted) {
      return;
    }
    setState(() => _log.add(line));
  }

  Future<void> _run() async {
    final Stopwatch total = Stopwatch()..start();
    try {
      final Directory? dir = await getExternalStorageDirectory();
      if (dir == null) {
        _say('拿不到外部目录');
        return;
      }
      final String inPath = '${dir.path}/$_inName';
      final String outPath = '${dir.path}/$_outName';
      _say('目录 ${dir.path}');
      final List<File> pdfs = dir
          .listSync()
          .whereType<File>()
          .where(
            (File f) =>
                f.path.toLowerCase().endsWith('.pdf') &&
                f.uri.pathSegments.last.startsWith(_batchPrefix),
          )
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
      if (pdfs.isNotEmpty) {
        _say('批量模式：${pdfs.length} 份 PDF');
        for (final File pdf in pdfs) {
          await _dump(pdf);
        }
        _say('批量完成，总耗时 ${total.elapsedMilliseconds}ms');
        return;
      }
      if (!File(inPath).existsSync()) {
        _say('输入文件不存在：$inPath');
        return;
      }
      final Stopwatch open = Stopwatch()..start();
      final PdfDocument doc = await PdfDocument.openFile(inPath);
      open.stop();
      _say('openFile ${open.elapsedMilliseconds}ms / ${doc.pages.length} 页');

      final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
      for (final PdfPage page in doc.pages) {
        final Stopwatch sw = Stopwatch()..start();
        final PdfPageText text = await page.loadStructuredText();
        sw.stop();
        final double h = page.height;
        final List<Map<String, Object?>> runs = <Map<String, Object?>>[];
        for (final PdfPageTextFragment f in text.fragments) {
          final PdfRect b = f.bounds;
          runs.add(<String, Object?>{
            't': f.text,
            'l': _r(b.left),
            'tp': _r(b.top),
            'r': _r(b.right),
            'bt': _r(b.bottom),
            // 页面坐标（左上原点，y 向下）
            'x': _r(b.left),
            'y': _r(h - b.top),
            'w': _r(b.width),
            'hh': _r(b.height),
            'dir': f.direction.name,
            'nchar': f.charRects.length,
          });
        }
        pages.add(<String, Object?>{
          'index': page.pageNumber - 1,
          'w': _r(page.width),
          'h': _r(h),
          'ms': sw.elapsedMilliseconds,
          'runs': runs,
        });
        _say(
          'p${page.pageNumber} ${page.width.toStringAsFixed(0)}×'
          '${h.toStringAsFixed(0)}pt ${runs.length} 片段 ${sw.elapsedMilliseconds}ms',
        );
      }

      final File out = File(outPath);
      await out.writeAsString(
        const JsonEncoder.withIndent(' ').convert(<String, Object?>{'pages': pages}),
        flush: true,
      );
      total.stop();
      _say('写入 ${out.path} ${out.lengthSync()}B / 总耗时 ${total.elapsedMilliseconds}ms');

      // 就地做一次朴素行聚类，只为让"阈值该取多少"有个直观数字
      final Map<String, Object?> first = pages.first;
      final List<Object?> runs = first['runs']! as List<Object?>;
      final List<double> ys = <double>[];
      final Map<double, StringBuffer> byY = <double, StringBuffer>{};
      for (final Object? raw in runs) {
        final Map<String, Object?> r = raw! as Map<String, Object?>;
        final String t = r['t']! as String;
        if (t.trim().isEmpty) {
          continue;
        }
        final double y = (r['y']! as num).toDouble();
        final double hh = (r['hh']! as num).toDouble();
        // 以片段垂直中心聚行，容差 0.5 倍行高
        double hit = double.nan;
        for (final double key in ys) {
          if ((key - y).abs() < hh * 0.5) {
            hit = key;
            break;
          }
        }
        if (hit.isNaN) {
          ys.add(y);
          byY[y] = StringBuffer();
          hit = y;
        }
        byY[hit]!.write(t);
      }
      ys.sort();
      _say('朴素聚类得到 ${ys.length} 行（第 1 页）');
      for (final double y in ys.take(18)) {
        _say('y=${y.toStringAsFixed(1)} | ${byY[y].toString().trim()}');
      }
      await doc.dispose();
    } on Object catch (error, stack) {
      _say('失败：$error');
      debugPrint('$stack');
    } finally {
      if (mounted) {
        setState(() => _done = true);
      }
    }
  }

  /// 把一份 PDF 的文本层原样倒成 JSON（评测语料用）。
  Future<void> _dump(File pdf) async {
    final String name = pdf.uri.pathSegments.last.replaceAll('.pdf', '');
    final Stopwatch sw = Stopwatch()..start();
    final PdfDocument doc = await PdfDocument.openFile(pdf.path);
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    int totalRuns = 0;
    for (final PdfPage page in doc.pages) {
      final PdfPageText text = await page.loadStructuredText();
      final double h = page.height;
      final List<Map<String, Object?>> runs = <Map<String, Object?>>[];
      for (final PdfPageTextFragment f in text.fragments) {
        final PdfRect b = f.bounds;
        runs.add(<String, Object?>{
          't': f.text,
          'x': _r(b.left),
          'y': _r(h - b.top),
          'w': _r(b.width),
          'h': _r(b.height),
        });
      }
      totalRuns += runs.length;
      pages.add(<String, Object?>{
        'index': page.pageNumber - 1,
        'w': _r(page.width),
        'h': _r(h),
        'runs': runs,
      });
    }
    await doc.dispose();
    final File out = File('${pdf.parent.path}/$name.json');
    await out.writeAsString(
      const JsonEncoder.withIndent(' ').convert(<String, Object?>{'pages': pages}),
      flush: true,
    );
    sw.stop();
    _say('$name: ${pages.length} 页 / $totalRuns 片段 / ${out.lengthSync()}B / ${sw.elapsedMilliseconds}ms');
  }

  static double _r(double value) => (value * 100).roundToDouble() / 100;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_done ? '取材完成' : '取材中…')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          for (final String line in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line, style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }
}
