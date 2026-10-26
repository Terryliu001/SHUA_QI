import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/region/confidence.dart';
import 'package:shuaqi/domain/region/layout_blocks.dart';
import 'package:shuaqi/domain/region/leveling.dart';
import 'package:shuaqi/domain/region/scan_lines.dart';
import 'package:shuaqi/domain/region/scan_split.dart';
import 'package:shuaqi/domain/region/split.dart';
import 'package:shuaqi/infra/pdf/pdf_source.dart';

/// 行级分析结果的进程内缓存。
///
/// 为什么需要：每次改框都是**整卷重算**（`RegionEditController` 的设计），
/// 而扫描件的行级分析要逐页渲染灰度 + 扫像素（约 10–15ms/页）。
/// 20 页的卷子连续拖三次框就是 20×3 次无用渲染。
///
/// 键 = `workbookId|页序|渲染宽度`。同一份 PDF 的像素永远不变，
/// 所以这份缓存**不需要失效逻辑**；只在超过 [_scanCacheLimit] 页时整体清空
/// （内存占用：一行约 60 字节，一页 50 行，可以忽略）。
final Map<String, ScanPage> _scanLineCache = <String, ScanPage>{};
const int _scanCacheLimit = 400;

/// L2 的**无 OCR 降级**：扫描件按版面切块（T3.3 的一部分）。
///
/// 两条路，先试"行级"，不行再退"块级"：
///
/// | 路径 | 依据 | 粒度 | 什么时候用 |
/// |---|---|---|---|
/// | [runScan]（2026-10-23 新增） | 行首短墨块 + 其后空白 + 左边距一致 | **题级** | 扫描件先走这条 |
/// | [run] | 纵向空白带（行距自适应） | 内容块级 | 行级一个题号也没找到时兜底 |
///
/// 为什么保留块级：整页是图片、竖排、或者题号样式特殊（手写编号、圈号印刷体）
/// 时，行级一条也命中不了。那时"切出 8 块、其中 6 块正好是题"仍然比"0 个框"好得多，
/// 而且用户改 2 处就能用。
class L2LayoutCutter {
  const L2LayoutCutter({required this.source, this.cacheId = ''});

  final PdfSource source;

  /// 缓存命名空间（传 workbookId）。空串 = 不缓存。
  final String cacheId;

  /// 块级路径的渲染分辨率（长边 px）。700 足够分辨行与行之间的空白带。
  static const int renderWidthPx = 700;

  /// 行级路径的渲染分辨率（长边 px）。
  ///
  /// 比块级高一档：题号检测要看清"行内 0.3 em 的空白"，
  /// A4 卷 1400 长边 → 宽约 990px，10pt 字约 17px，够。
  /// 代价是每页多 ~7ms 渲染（034 实测 700px 是 3–6ms/页）。
  static const int scanRenderWidthPx = 1400;

  static const int _maxBlocksPerPage = 40;

  /// 行级切题：整卷逐页分析 → 复用 L1 的切分引擎（见 `scan_split.dart`）。
  ///
  /// 返回 null 表示"一页都渲染不出来"；`regions` 少于 2 段时由调用方决定是否退块级。
  Future<SplitResult?> runScan(
    List<WbPage> pages, {
    bool Function()? isCancelled,
  }) async {
    final List<ScanPage> scans = <ScanPage>[];
    for (final WbPage page in pages) {
      if (isCancelled?.call() ?? false) {
        return null;
      }
      final String key =
          '$cacheId|${page.index}|$scanRenderWidthPx|${page.width.round()}x${page.height.round()}';
      final ScanPage? cached = cacheId.isEmpty ? null : _scanLineCache[key];
      if (cached != null) {
        scans.add(cached);
        continue;
      }
      final GrayPage? gray = await source.renderGray(
        page.index,
        widthPx: scanRenderWidthPx,
      );
      if (gray == null) {
        continue;
      }
      final ScanPage analyzed = analyzeScanPage(
        luma: gray.luma,
        width: gray.width,
        height: gray.height,
        pageIndex: page.index,
        pageWidthPt: page.width,
        pageHeightPt: page.height,
      );
      if (cacheId.isNotEmpty) {
        if (_scanLineCache.length >= _scanCacheLimit) {
          _scanLineCache.clear();
        }
        _scanLineCache[key] = analyzed;
      }
      scans.add(analyzed);
    }
    if (scans.isEmpty) {
      return null;
    }
    return splitScanPages(scans);
  }

  /// 块级兜底：逐页按"够宽的空白带"切块。
  Future<List<RegionDraft>> run(
    List<WbPage> pages, {
    bool Function()? isCancelled,
  }) async {
    final List<RegionDraft> drafts = <RegionDraft>[];
    int ordinal = 1;
    for (final WbPage page in pages) {
      if (isCancelled?.call() ?? false) {
        break;
      }
      final GrayPage? gray = await source.renderGray(
        page.index,
        widthPx: renderWidthPx,
      );
      if (gray == null || gray.width <= 0 || gray.height <= 0) {
        continue;
      }
      final List<LayoutBlock> blocks = detectLayoutBlocks(
        luma: gray.luma,
        width: gray.width,
        height: gray.height,
        pageWidthPt: page.width,
        pageHeightPt: page.height,
        options: const LayoutBlockOptions(maxBlocks: _maxBlocksPerPage),
      );
      for (final LayoutBlock block in blocks) {
        if (block.rect.height < 8) {
          continue;
        }
        drafts.add(
          RegionDraft(
            ordinal: ordinal,
            // 没有题号可给：用序号当标签，用户一眼知道"第几块"。
            label: '$ordinal',
            level: 2,
            kind: 'unknown',
            stem: '',
            slices: <PageSlice>[
              PageSlice(pageIndex: page.index, rect: block.rect),
            ],
            confidence: _confidence(block),
            fontSize: 0,
            source: 'layout',
            number: ordinal,
          ),
        );
        ordinal++;
      }
    }
    return drafts;
  }

  /// 块的可信度：边界（块间距）是可靠的，其余信号都没有 → 黄框。
  ///
  /// 按规格公式：0.45 + 0.2×边界(1) + 0.15×样式(0.5) + 0.1×顺序(0.5) + 0.1×题干(0)
  /// − 0.2（版面推断）≈ 0.575 → 黄。
  static double _confidence(LayoutBlock block) {
    // 太"空"的块（墨迹占比极低）再扣一点：多半是横线、水印或空白作答区。
    final double text = block.darkRatio < 0.02 ? 0.0 : 0.1;
    return regionConfidence(
      ConfidenceSignals(
        boundary: 1,
        style: 0.5,
        order: 0.5,
        text: text,
        fromOcr: true,
      ),
    );
  }
}

/// 把块换算成"一个块一题"的切题结果（复用 [SplitResult]，下游不用分叉）。
SplitResult layoutBlocksAsResult(
  List<RegionDraft> blocks, {
  required int pageCount,
}) {
  return SplitResult(
    regions: blocks,
    // 版面切块没有层级信息：全部按小题（level 2）处理，谁都能手改。
    leveling: const Leveling(levels: <int>[], basis: 'layout'),
    markCount: blocks.length,
    warnings: <String>[
      if (blocks.isEmpty)
        '这一卷没有文本层，版面也没能切出内容（整页空白或图片过淡）'
      else
        '这一卷没有文本层，已按版面切成 ${blocks.length} 块（共 $pageCount 页）：不是按题号切的，请逐块核对',
    ],
  );
}
