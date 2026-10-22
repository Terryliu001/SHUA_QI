import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shuaqi/domain/model/session.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:shuaqi/infra/db/app_database.dart';
import 'package:shuaqi/infra/db/dao/page_dao.dart';
import 'package:shuaqi/infra/db/dao/session_dao.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/infra/db/migrations.dart';
import 'package:sqflite/sqflite.dart';

/// T1.2 的数据库测试（规格要求 ≥6 例）。
///
/// **为什么放在 `integration_test/` 而不是 `test/`**：
/// T1.2 要验的是"真 sqflite 能建库、能级联删除、能跨版本迁移"，
/// 这必须跑在**真设备**的 sqlite 上。宿主机的替代方案是 `sqflite_common_ffi`，
/// 但它依赖 `sqlite3` 包，而 `sqlite3` 是 native assets 包——
/// 在本机沙箱里编译它需要的 Windows SDK 头文件定位要查注册表（reg.exe 被禁），
/// 结果是**整个 `flutter test` 套件一起挂掉**。宁可把 DB 测试放到设备上，也不能让
/// 纯 Dart 的 domain 测试失去宿主运行能力。
///
/// 运行方式（真机连上后）：
///   flutter test integration_test/db_test.dart -d `设备id`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String dbDir;
  late String dbPath;

  setUpAll(() async {
    dbDir = await getDatabasesPath();
  });

  setUp(() {
    // 每个用例一个独立库文件，避免相互污染
    dbPath = p.join(dbDir, 'test_${Ulid.next()}.db');
  });

  tearDown(() async {
    await databaseFactory.deleteDatabase(dbPath);
  });

  Workbook sampleWorkbook({
    String id = 'wb_1',
    String sha1 = 'sha1-a',
    int createdAt = 1000,
  }) {
    return Workbook(
      id: id,
      title: '数学分析（上）期中',
      sha1: sha1,
      pageCount: 2,
      pageSize: '{"w":595.3,"h":841.9}',
      sourcePath: 'workbooks/$id/source.pdf',
      createdAt: createdAt,
    );
  }

  /// ① 建库：六张核心表 + setting 都在
  test('建库后 7 张表齐全，且外键已打开', () async {
    final AppDatabase db = await AppDatabase.open(dbPath);
    addTearDown(db.close);

    final List<Map<String, Object?>> tables = await db.raw.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final Set<String> names = tables
        .map((Map<String, Object?> row) => row['name']! as String)
        .toSet();

    for (final String expected in <String>[
      'workbook',
      'wb_page',
      'session',
      'question',
      'question_region',
      'ink_state',
      'setting',
    ]) {
      expect(names, contains(expected), reason: '缺表 $expected');
    }

    // PRAGMA foreign_keys 在 onConfigure 里开，必须是 1
    final List<Map<String, Object?>> pragma = await db.raw.rawQuery(
      'PRAGMA foreign_keys',
    );
    expect(pragma.first.values.first, 1);
  });

  /// ② 插入一卷并按 sha1 / id 查回
  test('插入后能按 sha1 与 id 查回，字段不失真', () async {
    final AppDatabase db = await AppDatabase.open(dbPath);
    addTearDown(db.close);
    final WorkbookDao dao = WorkbookDao(db.raw);

    await dao.insert(sampleWorkbook());

    final Workbook? bySha1 = await dao.bySha1('sha1-a');
    expect(bySha1, isNotNull);
    expect(bySha1!.title, '数学分析（上）期中');
    expect(bySha1.pageCount, 2);
    expect(bySha1.pageSize, '{"w":595.3,"h":841.9}');
    expect(bySha1.openedAt, isNull);
    expect(bySha1.layoutStatus, LayoutStatus.none);

    final Workbook? byId = await dao.byId('wb_1');
    expect(byId!.id, 'wb_1');

    expect(await dao.bySha1('not-exist'), isNull);
  });

  /// ③ sha1 唯一：重复导入必须被数据库拦下
  test('sha1 唯一约束生效（重复导入抛异常）', () async {
    final AppDatabase db = await AppDatabase.open(dbPath);
    addTearDown(db.close);
    final WorkbookDao dao = WorkbookDao(db.raw);

    await dao.insert(sampleWorkbook(id: 'wb_1', sha1: 'same'));
    expect(
      () => dao.insert(sampleWorkbook(id: 'wb_2', sha1: 'same')),
      throwsA(isA<DatabaseException>()),
    );
  });

  /// ④ listByRecent：打开过的排在前面
  test('listByRecent 按"最近打开优先"排序', () async {
    final AppDatabase db = await AppDatabase.open(dbPath);
    addTearDown(db.close);
    final WorkbookDao dao = WorkbookDao(db.raw);

    await dao.insert(sampleWorkbook(id: 'wb_old', sha1: 's1', createdAt: 100));
    await dao.insert(sampleWorkbook(id: 'wb_new', sha1: 's2', createdAt: 200));
    await dao.insert(sampleWorkbook(id: 'wb_mid', sha1: 's3', createdAt: 150));

    // 还没打开过：按导入时间倒序
    List<Workbook> list = await dao.listByRecent();
    expect(
      list.map((Workbook w) => w.id).toList(),
      <String>['wb_new', 'wb_mid', 'wb_old'],
    );

    // 打开最旧的那本 → 它应该排到最前
    await dao.touchOpened('wb_old', 500);
    list = await dao.listByRecent();
    expect(
      list.map((Workbook w) => w.id).toList(),
      <String>['wb_old', 'wb_new', 'wb_mid'],
    );

    // 只保留一条时 limit 生效
    final List<Workbook> limited = await dao.listByRecent(limit: 1);
    expect(limited.length, 1);
    expect(limited.first.id, 'wb_old');
  });

  /// ⑤ 级联删除：删卷带走 wb_page / session / ink_state
  test('删除卷级联清理子表（wb_page / session / ink_state）', () async {
    final AppDatabase db = await AppDatabase.open(dbPath);
    addTearDown(db.close);
    final WorkbookDao books = WorkbookDao(db.raw);
    final PageDao pages = PageDao(db.raw);
    final SessionDao sessions = SessionDao(db.raw);

    await books.insert(sampleWorkbook());
    await pages.insertMany(<WbPage>[
      const WbPage(id: 'p0', workbookId: 'wb_1', index: 0, width: 595, height: 842),
      const WbPage(id: 'p1', workbookId: 'wb_1', index: 1, width: 595, height: 842),
    ]);
    final Session session = await sessions.createDraft('wb_1', now: 1);
    await db.raw.insert('ink_state', <String, Object?>{
      'page_id': 'p0',
      'session_id': session.id,
      'sif_path': 'workbooks/wb_1/sessions/s_1/ink/p000.sif',
    });

    expect(await books.delete('wb_1'), 1);

    expect(await pages.countOf('wb_1'), 0, reason: 'wb_page 应被级联删除');
    expect(await sessions.latestForWorkbook('wb_1'), isNull, reason: 'session 应被级联删除');
    final List<Map<String, Object?>> ink = await db.raw.query('ink_state');
    expect(ink, isEmpty, reason: 'ink_state 应被级联删除');
  });

  /// ⑥ 会话 seq 递增 + 状态机单向
  test('同一卷多次作答 seq 递增，状态机只允许单向推进', () async {
    final AppDatabase db = await AppDatabase.open(dbPath);
    addTearDown(db.close);
    final WorkbookDao books = WorkbookDao(db.raw);
    final SessionDao sessions = SessionDao(db.raw);

    await books.insert(sampleWorkbook());

    final Session first = await sessions.createDraft('wb_1', now: 10);
    expect(first.seq, 1);
    expect(first.state, SessionState.draft);

    final Session second = await sessions.createDraft('wb_1', now: 20);
    expect(second.seq, 2, reason: '二刷必须是独立的一条记录');

    expect((await sessions.latestForWorkbook('wb_1'))!.seq, 2);

    // draft → submitted 成功，再交一次应失败（返回 0）
    expect(await sessions.markSubmitted(first.id, at: 30), 1);
    expect(await sessions.markSubmitted(first.id, at: 31), 0);
    expect((await sessions.byId(first.id))!.submittedAt, 30);

    // 未交卷的不能直接归档
    expect(await sessions.archive(second.id), 0);
    // 已交卷的可以归档
    expect(await sessions.archive(first.id), 1);
    expect((await sessions.byId(first.id))!.state, SessionState.archived);
  });

  /// ⑦ 页顺序与 0-based 约定
  test('wb_page 按 idx 升序返回，且 0-based', () async {
    final AppDatabase db = await AppDatabase.open(dbPath);
    addTearDown(db.close);
    final WorkbookDao books = WorkbookDao(db.raw);
    final PageDao pages = PageDao(db.raw);

    await books.insert(sampleWorkbook());
    await pages.insertMany(<WbPage>[
      const WbPage(id: 'p2', workbookId: 'wb_1', index: 2, width: 595, height: 842),
      const WbPage(id: 'p0', workbookId: 'wb_1', index: 0, width: 595, height: 842),
      const WbPage(id: 'p1', workbookId: 'wb_1', index: 1, width: 1190, height: 842),
    ]);

    final List<WbPage> list = await pages.pagesOf('wb_1');
    expect(list.map((WbPage page) => page.index).toList(), <int>[0, 1, 2]);
    expect(list.first.index, 0, reason: '数据库存 0-based，显示时再 +1');
    // 混合纸张尺寸必须各自保留
    expect(list[1].width, 1190);
    expect((await pages.byIndex('wb_1', 1))!.id, 'p1');
    expect(await pages.byIndex('wb_1', 9), isNull);
  });

  /// ⑧ v1 → v2 迁移不丢数据
  test('v1 升级到 v2 后原有数据完整，且 setting 表可用', () async {
    // 先只建到 v1
    final AppDatabase v1 = await AppDatabase.open(dbPath, targetVersion: 1);
    await WorkbookDao(v1.raw).insert(sampleWorkbook());
    await PageDao(v1.raw).insertMany(<WbPage>[
      const WbPage(id: 'p0', workbookId: 'wb_1', index: 0, width: 595, height: 842),
    ]);
    final int beforeVersion = await v1.raw.getVersion();
    await v1.close();
    expect(beforeVersion, 1);

    // 再用最新版本打开，触发 onUpgrade
    final AppDatabase v2 = await AppDatabase.open(dbPath);
    addTearDown(v2.close);
    expect(await v2.raw.getVersion(), kDatabaseVersion);

    final Workbook? kept = await WorkbookDao(v2.raw).bySha1('sha1-a');
    expect(kept, isNotNull, reason: '升级不能丢卷');
    expect(kept!.title, '数学分析（上）期中');
    expect(await PageDao(v2.raw).countOf('wb_1'), 1, reason: '升级不能丢页');

    // 新表可写
    await v2.raw.insert('setting', <String, Object?>{
      'k': 'reader.default_paper_style',
      'v': 'warm',
    });
    final List<Map<String, Object?>> rows = await v2.raw.query('setting');
    expect(rows.single['v'], 'warm');
  });

  /// 补充：迁移清单本身的自检（防止有人插错版本号）
  test('迁移清单版本号从 1 连续递增，语句非空', () {
    for (int i = 0; i < kMigrations.length; i++) {
      expect(kMigrations[i].version, i + 1, reason: '版本号必须连续');
      expect(kMigrations[i].statements, isNotEmpty);
      for (final String statement in kMigrations[i].statements) {
        expect(statement.trim(), isNotEmpty);
      }
    }
    expect(kDatabaseVersion, kMigrations.length);
  });

  /// 补充：ULID 主键在库里可按时间排序
  test('用 ULID 作主键时，字符串序等于插入时间序', () async {
    final AppDatabase db = await AppDatabase.open(dbPath);
    addTearDown(db.close);
    final WorkbookDao dao = WorkbookDao(db.raw);

    final String early = Ulid.next(DateTime.utc(2026, 1, 1));
    final String late = Ulid.next(DateTime.utc(2026, 12, 1));
    await dao.insert(sampleWorkbook(id: late, sha1: 's-late', createdAt: 2));
    await dao.insert(sampleWorkbook(id: early, sha1: 's-early', createdAt: 1));

    final List<Map<String, Object?>> rows = await db.raw.query(
      'workbook',
      orderBy: 'id ASC',
    );
    expect(rows.first['id'], early);
    expect(rows.last['id'], late);
  });
}
