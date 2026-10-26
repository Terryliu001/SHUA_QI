import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/app/cache_report.dart';

/// 缓存统计的口径（2026-10-26 用户第 4 条：存储与备份 → 缓存统计与清除）。
///
/// ## 为什么这些数字要钉住
/// "能清多少"和"不能清什么"是这个功能的安全边界：
/// 笔迹、收藏、个人空间一旦被当成缓存删掉，用户损失的是不可恢复的东西。
/// 所以"哪些可清"写进 [CacheCategory.clearable]，并在这里钉死。
void main() {
  test('字节数按 1024 进位，可读性稳定', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(999), '999 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(1024 * 1024), '1.0 MB');
    expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
    expect(formatBytes(1024 * 1024 * 1024), '1.00 GB');
  });

  test('负数与零都归到 0 B（不出现负数）', () {
    expect(formatBytes(-1), '0 B');
  });

  test('只有可清理的分类计入可释放体积', () {
    const CacheReport report = CacheReport(<CacheEntry>[
      CacheEntry(category: CacheCategory.ink, bytes: 900, files: 3),
      CacheEntry(category: CacheCategory.thumbnails, bytes: 100, files: 2),
      CacheEntry(category: CacheCategory.answerCrops, bytes: 50, files: 1),
      CacheEntry(category: CacheCategory.favorites, bytes: 800, files: 4),
    ]);
    expect(report.totalBytes, 1850);
    expect(report.totalFiles, 10);
    expect(report.clearableBytes, 150);
    expect(report.clearableFiles, 3);
    expect(report.hasClearable, isTrue);
  });

  test('没有可清理项时 hasClearable 为假（按钮应为禁用）', () {
    const CacheReport report = CacheReport(<CacheEntry>[
      CacheEntry(category: CacheCategory.ink, bytes: 10, files: 1),
    ]);
    expect(report.hasClearable, isFalse);
    expect(report.clearableBytes, 0);
  });

  test('用户数据一律不可清理', () {
    const List<CacheCategory> never = <CacheCategory>[
      CacheCategory.sourcePdf,
      CacheCategory.layout,
      CacheCategory.ink,
      CacheCategory.favorites,
      CacheCategory.profile,
      CacheCategory.feedback,
      CacheCategory.database,
    ];
    for (final CacheCategory category in never) {
      expect(category.clearable, isFalse, reason: '${category.label} 不能被清');
    }
  });

  test('entryOf 找不到时给一个空条目而不是抛异常', () {
    const CacheReport report = CacheReport(<CacheEntry>[]);
    final CacheEntry entry = report.entryOf(CacheCategory.ink);
    expect(entry.bytes, 0);
    expect(entry.files, 0);
    expect(entry.isEmpty, isTrue);
  });

  test('清理文案按实际释放量说话', () {
    expect(cacheClearedMessage(bytes: 0, files: 0), '没有可清理的缓存');
    expect(cacheClearedMessage(bytes: 2048, files: 3), '已清理 2.0 KB（3 个文件）');
  });
}
