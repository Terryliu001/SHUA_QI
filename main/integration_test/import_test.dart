import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/app/import/import_workbook.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/infra/db/dao/page_dao.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/infra/vault/file_hash.dart';
import 'package:shuaqi/infra/vault/paths.dart';

/// T1.3 导入管线的真机测试。
///
/// 刻意用 `bootstrap()` 打开**应用真实的数据库与 Vault**，而不是临时目录：
/// 这样测试跑完，App 打开就能在书架上看到这份卷子——测完即用，不用再手工造数据。
///
/// 素材：`getApplicationSupportDirectory()/paper_math_midterm.pdf`
/// （由 `adb` + base64 推进去的那份真实试卷；没有就跳过，不判失败）。
///
/// 运行：`flutter test integration_test/import_test.dart -d <设备>`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AppDependencies deps;
  late File source;

  setUpAll(() async {
    deps = await bootstrap();
    final Directory support = await getApplicationSupportDirectory();
    source = File(p.join(support.path, 'paper_math_midterm.pdf'));
  });

  test('真实试卷能导入：落文件、落库、出缩略图、可查重', () async {
    if (!source.existsSync()) {
      // 素材没推上来时跳过：这条测试的价值在真机真文件，不伪造素材。
      markTestSkipped('缺少测试素材：${source.path}');
      return;
    }

    final String sha1Hex = await sha1OfFile(source);
    final WorkbookDao books = WorkbookDao(deps.db.raw);
    final PageDao pages = PageDao(deps.db.raw);

    // 允许重复运行：先清掉上一次留下的同一份卷，保证从干净状态验
    final Workbook? stale = await books.bySha1(sha1Hex);
    if (stale != null) {
      await books.delete(stale.id);
      await deps.vault.deleteWorkbook(stale.id);
    }

    final WorkbookImporter importer = WorkbookImporter(
      db: deps.db,
      vault: deps.vault,
    );

    final List<String> stages = <String>[];
    final ImportOutcome first = await importer.run(
      source,
      onProgress: stages.add,
    );

    expect(first.deduped, isFalse);
    expect(stages, isNotEmpty, reason: '导入应上报阶段');
    expect(first.workbook.pageCount, greaterThan(0));
    expect(first.thumbCount, greaterThan(0), reason: '至少要有一张缩略图');

    // ① 文件层：原卷 / 元数据 / 缩略图都在
    expect(
      deps.vault.file(VaultPaths.sourcePdf(first.workbook.id)).existsSync(),
      isTrue,
    );
    expect(
      deps.vault.file(VaultPaths.metaJson(first.workbook.id)).existsSync(),
      isTrue,
    );
    expect(
      deps.vault.file(VaultPaths.thumb(first.workbook.id, 0)).existsSync(),
      isTrue,
    );

    // ② 数据库层：卷与逐页记录一致
    final Workbook? stored = await books.bySha1(sha1Hex);
    expect(stored, isNotNull);
    expect(stored!.id, first.workbook.id);
    expect(stored.title, isNotEmpty);

    final List<WbPage> storedPages = await pages.pagesOf(first.workbook.id);
    expect(storedPages.length, first.workbook.pageCount);
    expect(storedPages.first.index, 0, reason: '页序 0-based');
    // A4 的一个合理区间（pt）
    expect(storedPages.first.width, greaterThan(400));
    expect(storedPages.first.height, greaterThan(600));

    // ③ 再导一次：必须命中查重，不产生新卷
    final ImportOutcome second = await importer.run(source);
    expect(second.deduped, isTrue);
    expect(second.workbook.id, first.workbook.id);

    final List<Workbook> all = await books.listByRecent();
    final int sameSha1 = all
        .where((Workbook book) => book.sha1 == sha1Hex)
        .length;
    expect(sameSha1, 1, reason: '同一份文件只能有一条卷记录');
  });

  test('导入不存在的文件会抛 ImportException，且不留目录', () async {
    final WorkbookImporter importer = WorkbookImporter(
      db: deps.db,
      vault: deps.vault,
    );
    final List<String> before = await deps.vault.workbookIdsOnDisk();

    await expectLater(
      importer.run(File(p.join(deps.vault.rootPath, 'nope.pdf'))),
      throwsA(isA<ImportException>()),
    );

    final List<String> after = await deps.vault.workbookIdsOnDisk();
    expect(after.length, before.length, reason: '失败不许留下空目录');
  });
}
