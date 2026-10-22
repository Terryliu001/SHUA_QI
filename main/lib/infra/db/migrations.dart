/// 版本化迁移（规格 §5.2 的 DDL，逐字照抄，不许改列名）。
///
/// 规则：
/// 1. **只追加，不修改历史版本**。已经发出去的 v1 永远是这 6 张表的样子。
/// 2. 每个 Migration 只做一件事（建表 / 加索引 / 加列），便于定位"哪一版引入的问题"。
/// 3. 迁移里不许写业务数据（不 INSERT 默认行），默认值用列上的 DEFAULT。
library;

/// 一个版本的迁移。
class Migration {
  const Migration({
    required this.version,
    required this.statements,
    required this.note,
  });

  /// 从 1 开始、连续递增。
  final int version;

  /// 按顺序执行的 SQL 语句。
  final List<String> statements;

  /// 这一版为什么存在。写给人看，出现问题时靠它定位。
  final String note;
}

/// 当前全部迁移。**最后一版的 version 就是数据库版本号**。
const List<Migration> kMigrations = <Migration>[
  Migration(
    version: 1,
    note: 'T1.2 六张核心表（workbook / wb_page / session / question / question_region / ink_state）',
    statements: <String>[
      '''
CREATE TABLE workbook(
  id TEXT PRIMARY KEY, title TEXT NOT NULL, sha1 TEXT NOT NULL UNIQUE,
  page_count INTEGER NOT NULL, page_size TEXT NOT NULL, source_path TEXT NOT NULL,
  created_at INTEGER NOT NULL, opened_at INTEGER, last_session_id TEXT,
  layout_status TEXT NOT NULL DEFAULT 'none'
)''',
      '''
CREATE TABLE wb_page(
  id TEXT PRIMARY KEY, workbook_id TEXT NOT NULL REFERENCES workbook(id) ON DELETE CASCADE,
  idx INTEGER NOT NULL, w REAL NOT NULL, h REAL NOT NULL, UNIQUE(workbook_id, idx)
)''',
      '''
CREATE TABLE session(
  id TEXT PRIMARY KEY, workbook_id TEXT NOT NULL REFERENCES workbook(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'draft',
  started_at INTEGER NOT NULL, submitted_at INTEGER, last_page INTEGER DEFAULT 0,
  UNIQUE(workbook_id, seq)
)''',
      '''
CREATE TABLE question(
  id TEXT PRIMARY KEY, workbook_id TEXT NOT NULL REFERENCES workbook(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL, label TEXT, level INTEGER NOT NULL DEFAULT 2, parent_id TEXT,
  kind TEXT NOT NULL DEFAULT 'unknown', stem_text TEXT, confidence REAL NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'rule'
)''',
      '''
CREATE TABLE question_region(
  id TEXT PRIMARY KEY, question_id TEXT NOT NULL REFERENCES question(id) ON DELETE CASCADE,
  page_id TEXT NOT NULL REFERENCES wb_page(id) ON DELETE CASCADE,
  x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
  role TEXT NOT NULL DEFAULT 'mixed', confidence REAL NOT NULL DEFAULT 0,
  locked INTEGER NOT NULL DEFAULT 0
)''',
      '''
CREATE TABLE ink_state(
  page_id TEXT PRIMARY KEY REFERENCES wb_page(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL DEFAULT 0, stroke_count INTEGER NOT NULL DEFAULT 0,
  byte_size INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1,
  last_ocr_at INTEGER, sif_path TEXT NOT NULL, dirty_since INTEGER
)''',
    ],
  ),
  Migration(
    version: 2,
    note: 'setting 表：阅读偏好等键值设置（§5.3A）。T1.2 的"6 张表"没列它，'
        '但本周就要写 reader.* 键，所以单独一版加，顺带作为迁移机制的第一个真实用例。',
    statements: <String>[
      'CREATE TABLE setting(k TEXT PRIMARY KEY, v TEXT NOT NULL)',
    ],
  ),
];

/// 数据库最终版本号。
int get kDatabaseVersion => kMigrations.last.version;

/// 取 [fromVersion]（不含）到 [toVersion]（含）之间要执行的语句，按版本升序摊平。
List<String> statementsBetween({required int fromVersion, required int toVersion}) {
  final List<String> result = <String>[];
  for (final Migration migration in kMigrations) {
    if (migration.version > fromVersion && migration.version <= toVersion) {
      result.addAll(migration.statements);
    }
  }
  return result;
}
