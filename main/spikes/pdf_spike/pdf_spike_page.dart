import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shuaqi/infra/pdf/pdf_source.dart';

import 'pdfrx_source.dart';

/// T0.4 PDF spike：只回答四个问题——
/// 首屏多久、翻页多久、400% 清不清楚、文本层能不能拿到坐标（与"近似字号"）。
///
/// 文件来源：`/sdcard/Android/data/com.shuaqi.shuaqi/files/*.pdf`（用 adb push 放进去）。
class PdfSpikePage extends StatefulWidget {
  const PdfSpikePage({super.key});

  @override
  State<PdfSpikePage> createState() => _PdfSpikePageState();
}

class _PdfSpikePageState extends State<PdfSpikePage> {
  final List<String> _log = <String>[];
  List<File> _files = <File>[];
  String? _selected;
  bool _busy = false;

  /// 候选目录，按优先级从"最像产品"到"最临时"排列。
  ///
  /// 为什么不止一个：
  /// - **应用内部 files/** 是产品 Vault 的真实位置（T1.3 就落这里），但它只能由应用自己写，
  ///   外部文件靠 `adb shell run-as ... base64 -d > files/x.pdf` 推进来。
  /// - `/sdcard/Android/data/<pkg>/files` 用 adb push 最方便，**但目录若是 shell 创建的，
  ///   应用读它会被 scoped storage 拒绝**（实测 `PathAccessException ... errno = 13`）。
  /// - `code_cache`（= `Directory.systemTemp`）是最后兜底。
  ///
  /// 产品代码里不允许出现这种"猜目录"的写法：T1.3 会由 path_provider 给出确定路径。
  List<String> get _candidateDirs {
    final String internalRoot = Directory.systemTemp.parent.path;
    return <String>[
      '$internalRoot/files',
      '/storage/emulated/0/Android/data/com.shuaqi.shuaqi/files',
      Directory.systemTemp.path,
    ];
  }

  String _dir = '';

  @override
  void initState() {
    super.initState();
    // 放到首帧之后：_scan 里会 setState 写日志，直接在 initState 里跑会撞 build 期断言。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      unawaited(_scan());
    });
  }

  double get _dpr => ui.PlatformDispatcher.instance.views.first.devicePixelRatio;

  Future<void> _scan() async {
    List<File> found = <File>[];
    String usedDir = '';
    final List<String> failures = <String>[];
    for (final String candidate in _candidateDirs) {
      try {
        final List<File> pdfs = Directory(candidate)
            .listSync()
            .whereType<File>()
            .where((File file) => file.path.toLowerCase().endsWith('.pdf'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
        usedDir = candidate;
        found = pdfs;
        break;
      } on FileSystemException catch (error) {
        failures.add('$candidate → ${error.osError?.message ?? error.message}');
      }
    }
    setState(() {
      _dir = usedDir;
      _files = found;
      _selected = found.isEmpty ? null : found.first.path;
    });
    _log.clear();
    for (final String failure in failures) {
      _add('跳过（不可读）：$failure');
    }
    _add('使用目录 $_dir，找到 ${found.length} 个 PDF');
    for (final File file in found) {
      _add(
        '  · ${file.uri.pathSegments.last}  '
        '${(file.lengthSync() / 1024).toStringAsFixed(0)} KB',
      );
    }
  }

  Future<void> _measureSelected() async {
    final String? path = _selected;
    if (path == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _log.clear();
    });
    _add('=== ${File(path).uri.pathSegments.last} ===');
    _add('devicePixelRatio = ${_dpr.toStringAsFixed(2)}');

    PdfrxSource? source;
    final Stopwatch watch = Stopwatch();
    final int rssBefore = ProcessInfo.currentRss;
    try {
      // ① 打开
      watch
        ..reset()
        ..start();
      source = await PdfrxSource.open(path);
      watch.stop();
      final int openMs = watch.elapsedMilliseconds;
      _add(
        '① openFile: $openMs ms  '
        '(${source.pageCount} 页)',
      );

      final ui.Size size0 = source.pageSize(0);
      _add(
        '   第 1 页尺寸 ${size0.width.toStringAsFixed(1)} × '
        '${size0.height.toStringAsFixed(1)} pt',
      );

      // 首屏用的像素密度：按"页高铺满屏幕高度"估算，即 fit-height
      final double longEdgePt = math.max(size0.width, size0.height);
      final double fitPx = longEdgePt * _dpr;

      // ② 首屏 = open + 第 1 页渲染
      watch
        ..reset()
        ..start();
      final PdfImage? first = await source.renderRaw(0, maxEdgePx: fitPx);
      watch.stop();
      final int firstMs = watch.elapsedMilliseconds;
      _add(
        '② 第 1 页渲染: $firstMs ms  '
        '→ ${first?.width}×${first?.height} px',
      );
      first?.dispose();
      _add('   **首屏合计 ≈ ${openMs + firstMs} ms**（通过线 ≤2000ms）');

      // ③ 翻页：连续渲染前 20 页，取中位数（不含 open）
      final int pages = math.min(20, source.pageCount);
      final List<int> turns = <int>[];
      for (int i = 1; i < pages; i++) {
        watch
          ..reset()
          ..start();
        final PdfImage? image = await source.renderRaw(i, maxEdgePx: fitPx);
        watch.stop();
        image?.dispose();
        turns.add(watch.elapsedMilliseconds);
      }
      if (turns.isNotEmpty) {
        turns.sort();
        _add(
          '③ 翻页渲染 ${turns.length} 次: '
          '中位 ${turns[turns.length ~/ 2]} ms / '
          '最小 ${turns.first} ms / 最大 ${turns.last} ms'
          '（通过线 ≤200ms）',
        );
      }

      // ④ PNG 编码成本（契约要求返回 Uint8List，这一步能否忽略要看数字）
      watch
        ..reset()
        ..start();
      final Uint8List png = await source.renderPage(0, maxEdgePx: fitPx);
      watch.stop();
      _add(
        '④ renderPage 含 PNG 编码: ${watch.elapsedMilliseconds} ms, '
        '${(png.length / 1024).toStringAsFixed(0)} KB '
        '（减去 ② 即为编码净成本）',
      );

      // ⑤ 400% 清晰度
      watch
        ..reset()
        ..start();
      final PdfImage? big = await source.renderRaw(
        0,
        maxEdgePx: longEdgePt * 4,
      );
      watch.stop();
      _add(
        '⑤ 400% 渲染: ${watch.elapsedMilliseconds} ms '
        '→ ${big?.width}×${big?.height} px',
      );
      big?.dispose();

      // ⑤b 真实 400%：400% × dpr 才是"屏幕上看 400% 时需要的像素密度"
      const double zoom = 4;
      final double pxPerPt = zoom * _dpr;
      watch
        ..reset()
        ..start();
      final PdfImage? crop = await source.renderCrop(
        0,
        cropPt: const ui.Rect.fromLTWH(30, 30, 200, 120),
        pxPerPt: pxPerPt,
      );
      watch.stop();
      _add(
        '⑤b 真实 400%（${pxPerPt.toStringAsFixed(1)} px/pt）'
        '一块 200×120pt: ${watch.elapsedMilliseconds} ms '
        '→ ${crop?.width}×${crop?.height} px',
      );
      if (crop != null) {
        final Uint8List cropPng = await PdfrxSource.encodePng(crop);
        final File out = File(
          '${Directory.systemTemp.parent.path}/files/crop400.png',
        );
        await out.writeAsBytes(cropPng);
        _add(
          '   已存裁图 ${(cropPng.length / 1024).toStringAsFixed(0)} KB → ${out.path}',
        );
        crop.dispose();
      }
      final double fullW = size0.width * pxPerPt;
      final double fullH = size0.height * pxPerPt;
      _add(
        '   若整页按同样倍率渲染: ${fullW.round()}×${fullH.round()} px '
        '≈ ${(fullW * fullH * 4 / 1048576).toStringAsFixed(0)} MB 位图 '
        '→ **必须分块渲染**',
      );

      // ⑥ 文本层
      watch
        ..reset()
        ..start();
      final List<TextRun> runs = await source.extractText(0);
      watch.stop();
      _add('⑥ 文本层抽取: ${watch.elapsedMilliseconds} ms, ${runs.length} 个片段');

      if (runs.isEmpty) {
        _add('   **没有文本层** → L0 失效，这份卷子必须走 L2 补位');
      } else {
        final Map<int, int> heightHist = <int, int>{};
        for (final TextRun run in runs) {
          final int key = run.height.round();
          heightHist[key] = (heightHist[key] ?? 0) + 1;
        }
        final List<MapEntry<int, int>> top = heightHist.entries.toList()
          ..sort(
            (MapEntry<int, int> a, MapEntry<int, int> b) =>
                b.value.compareTo(a.value),
          );
        _add(
          '   片段高度分布（近似字号 pt）: '
          '${top.take(5).map((MapEntry<int, int> e) => '${e.key}pt×${e.value}').join(', ')}',
        );

        final RegExp questionNo = RegExp(r'^\s*(\d{1,3})\s*[.、．]\s*');
        final int hits = runs
            .where((TextRun run) => questionNo.hasMatch(run.text))
            .length;
        _add('   题号正则命中: $hits / ${runs.length} 个片段');

        for (final TextRun run in runs.take(5)) {
          _add(
            '   · "${run.text.trim()}" @(${run.x.toStringAsFixed(0)},'
            '${run.y.toStringAsFixed(0)}) '
            '${run.width.toStringAsFixed(0)}×${run.height.toStringAsFixed(1)} '
            'fs≈${run.fontSize.toStringAsFixed(1)}',
          );
        }
      }

      // ⑦ 内存
      final int rssAfter = ProcessInfo.currentRss;
      _add(
        '⑦ RSS: ${(rssBefore / 1048576).toStringAsFixed(0)} → '
        '${(rssAfter / 1048576).toStringAsFixed(0)} MB '
        '(+${((rssAfter - rssBefore) / 1048576).toStringAsFixed(0)} MB)',
      );
    } on Object catch (error) {
      _add('!! 异常：$error');
    } finally {
      await source?.dispose();
      setState(() {
        _busy = false;
      });
    }
  }

  void _add(String line) {
    setState(() {
      _log.add(line);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('T0.4 PDF spike')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '文件来源 $_dir',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final File file in _files)
                  ChoiceChip(
                    label: Text(
                      '${file.uri.pathSegments.last} '
                      '(${(file.lengthSync() / 1024).toStringAsFixed(0)}KB)',
                    ),
                    selected: _selected == file.path,
                    onSelected: (bool _) {
                      setState(() {
                        _selected = file.path;
                      });
                    },
                  ),
                OutlinedButton(onPressed: _scan, child: const Text('重新扫描')),
                FilledButton(
                  onPressed: _busy ? null : () => unawaited(_measureSelected()),
                  child: Text(_busy ? '测量中…' : '全项测量'),
                ),
              ],
            ),
            const Divider(height: 20),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _log.join('\n'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
