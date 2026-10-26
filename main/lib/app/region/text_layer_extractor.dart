import 'package:shuaqi/domain/region/page_layout.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/split.dart';
import 'package:shuaqi/domain/region/text_json.dart';
import 'package:shuaqi/domain/region/text_line.dart';
import 'package:shuaqi/infra/pdf/pdf_source.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';

/// 一次文本层抽取的结果（给日志 / HUD / 状态栏用）。
class TextExtractOutcome {
  const TextExtractOutcome({
    required this.pageCount,
    required this.runCount,
    required this.lineCount,
    required this.elapsed,
    this.cancelled = false,
  });

  final int pageCount;
  final int runCount;
  final int lineCount;
  final Duration elapsed;
  final bool cancelled;
}

/// L0：把 PDF 文本层抽成"带坐标的行"，落到 `layout/text.json`（T3.1）。
///
/// ## 为什么逐页 `await` + 让出事件循环，而不是丢进 isolate
///
/// pdfrx 的 `PdfDocument` 不是线程安全的，文本层只能在主 isolate 调。
/// 真机实测 1–10ms/页，20 页卷总耗时 <200ms；把它切成"每页之间让一帧"，
/// 用户完全无感，也不需要为了 200ms 引入 isolate 与序列化开销。
///
/// ## 为什么只存行、不存片段
///
/// 见 `domain/region/text_json.dart` 的文件头：原始片段是实现细节，
/// 行（一句话 + 位置）才是切题的输入、也是后续可以整份喂给 AI 的形态。
class TextLayerExtractor {
  const TextLayerExtractor({required this.source, required this.store});

  final PdfSource source;
  final LayoutStore store;

  Future<TextExtractOutcome> run(
    String workbookId, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    DateTime? now,
  }) async {
    final Stopwatch watch = Stopwatch()..start();
    final int total = source.pageCount;
    final List<PageLines> pages = <PageLines>[];
    final Map<int, int> runCounts = <int, int>{};
    int runCount = 0;
    int lineCount = 0;
    bool cancelled = false;

    for (int index = 0; index < total; index++) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final List<TextRun> runs = await source.extractText(index);
      runCounts[index] = runs.length;
      final List<TextPiece> pieces = <TextPiece>[
        for (final TextRun run in runs)
          if (run.text.trim().isNotEmpty && run.width > 0 && run.height > 0)
            TextPiece(
              text: run.text,
              rect: RegionRect.fromLTRB(
                run.x,
                run.y,
                run.x + run.width,
                run.y + run.height,
              ),
              fontSize: run.fontSize,
            ),
      ];
      runCount += runs.length;
      final PageLines page = buildPageLines(
        pageIndex: index,
        width: source.pageSize(index).width,
        height: source.pageSize(index).height,
        pieces: pieces,
      );
      lineCount += page.lines.length;
      pages.add(page);
      onProgress?.call(index + 1, total);
      // 让出一次事件循环：20 页也不会让界面掉帧（每页只阻塞 ~10ms）。
      await Future<void>.delayed(Duration.zero);
    }

    if (!cancelled && pages.isNotEmpty) {
      await store.writeText(
        workbookId,
        encodeTextDocument(
          pages,
          extractedAtMillis: (now ?? DateTime.now())
              .toUtc()
              .millisecondsSinceEpoch,
          runCounts: runCounts,
        ),
      );
    }
    watch.stop();
    return TextExtractOutcome(
      pageCount: pages.length,
      runCount: runCount,
      lineCount: lineCount,
      elapsed: watch.elapsed,
      cancelled: cancelled,
    );
  }
}
