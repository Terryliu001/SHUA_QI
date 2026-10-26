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
    note:
        'setting 表：阅读偏好等键值设置（§5.3A）。T1.2 的"6 张表"没列它，'
        '但本周就要写 reader.* 键，所以单独一版加，顺带作为迁移机制的第一个真实用例。',
    statements: <String>[
      'CREATE TABLE setting(k TEXT PRIMARY KEY, v TEXT NOT NULL)',
    ],
  ),
  Migration(
    version: 3,
    note:
        '书架管理（2026-10-23）：workbook 加 folder（文件夹）与 tags（逗号分隔标签）。'
        "两者都是 TEXT NOT NULL DEFAULT ''，老数据自动落到「未分类 / 无标签」，无需回填。",
    statements: <String>[
      "ALTER TABLE workbook ADD COLUMN folder TEXT NOT NULL DEFAULT ''",
      "ALTER TABLE workbook ADD COLUMN tags TEXT NOT NULL DEFAULT ''",
      'CREATE INDEX idx_workbook_folder ON workbook(folder)',
    ],
  ),
  Migration(
    version: 4,
    note:
        '嵌套文件夹 + 标签颜色（2026-10-24 第二轮）：'
        'folder 独立成表（id/name/parent_id/color/sort）才能放子文件夹；'
        'workbook 加 folder_id 指向它。tag 表只存"标签 → 颜色"，'
        '标签本身仍留在 workbook.tags（逗号分隔），改名/删标签不需要级联。',
    statements: <String>[
      '''
CREATE TABLE folder(
  id TEXT PRIMARY KEY, name TEXT NOT NULL,
  parent_id TEXT NOT NULL DEFAULT '', color TEXT NOT NULL DEFAULT '',
  sort INTEGER NOT NULL DEFAULT 0
)''',
      "ALTER TABLE workbook ADD COLUMN folder_id TEXT NOT NULL DEFAULT ''",
      'CREATE INDEX idx_folder_parent ON folder(parent_id)',
      'CREATE INDEX idx_workbook_folder_id ON workbook(folder_id)',
      '''
CREATE TABLE tag(
  name TEXT PRIMARY KEY, color TEXT NOT NULL DEFAULT ''
)''',
    ],
  ),
  Migration(
    version: 5,
    note:
        'AI token 用量（2026-10-24）：每次调用记一行，设置页看累计与最近记录。'
        '不改任何既有表，只在末尾追加；端点没返回 usage 时 estimated=1（按字符估算）。',
    statements: <String>[
      '''
CREATE TABLE llm_usage(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  model TEXT NOT NULL DEFAULT '',
  task TEXT NOT NULL DEFAULT '',
  tokens_in INTEGER NOT NULL DEFAULT 0,
  tokens_out INTEGER NOT NULL DEFAULT 0,
  estimated INTEGER NOT NULL DEFAULT 0,
  ok INTEGER NOT NULL DEFAULT 1
)''',
      'CREATE INDEX idx_llm_usage_at ON llm_usage(at)',
    ],
  ),
  Migration(
    version: 6,
    note:
        '收藏夹（2026-10-25）：收藏的题从「每卷一个 id 列表」升级为**跨卷独立快照库**。'
        'favorite 表**不设**指向 workbook/question 的外键——原卷删除后收藏仍保留'
        '（source_deleted 标记来源卷已删，题面/笔迹/AI 对话走 Vault 快照目录）。'
        'favorite_set / favorite_set_item 是「组卷冲刷」的命名题集（T8.4）。',
    statements: <String>[
      '''
CREATE TABLE favorite(
  id TEXT PRIMARY KEY,
  question_id TEXT NOT NULL DEFAULT '',
  workbook_id TEXT NOT NULL DEFAULT '',
  workbook_title TEXT NOT NULL DEFAULT '',
  label TEXT NOT NULL DEFAULT '',
  ordinal INTEGER NOT NULL DEFAULT 0,
  kind TEXT NOT NULL DEFAULT 'unknown',
  stem_text TEXT NOT NULL DEFAULT '',
  page_index INTEGER NOT NULL DEFAULT 0,
  rect TEXT NOT NULL DEFAULT '',
  knowledge_tags TEXT NOT NULL DEFAULT '',
  verdict TEXT NOT NULL DEFAULT 'none',
  source_deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)''',
      'CREATE INDEX idx_favorite_updated ON favorite(updated_at)',
      'CREATE INDEX idx_favorite_workbook ON favorite(workbook_id)',
      '''
CREATE TABLE favorite_set(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)''',
      '''
CREATE TABLE favorite_set_item(
  set_id TEXT NOT NULL REFERENCES favorite_set(id) ON DELETE CASCADE,
  favorite_id TEXT NOT NULL REFERENCES favorite(id) ON DELETE CASCADE,
  sort INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(set_id, favorite_id)
)''',
      'CREATE INDEX idx_favorite_set_item_set ON favorite_set_item(set_id)',
    ],
  ),
  Migration(
    version: 7,
    note:
        '作答记录（2026-10-25，阶段 9）：记录页要"哪天做了几题"，但 session 每卷只有一行、'
        'grading 的 at 是整批改卷时间，都推不出来，所以单独记事件。'
        '**不设外键**：卷删了"我做过 5 道题"这件事仍然成立，卷名/题号在写入时抄一份快照。'
        'UNIQUE(question_id, day)：同一天同一道题只算一次（热力图数的是题目数，'
        '动作次数记在 hits 列），day 是**本地** yyyy-MM-dd，避免晚上做的题掉到第二天。',
    statements: <String>[
      '''
CREATE TABLE answer_log(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  day TEXT NOT NULL,
  workbook_id TEXT NOT NULL DEFAULT '',
  workbook_title TEXT NOT NULL DEFAULT '',
  question_id TEXT NOT NULL DEFAULT '',
  label TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL DEFAULT 'unknown',
  page_index INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'ink',
  verdict TEXT NOT NULL DEFAULT 'none',
  hits INTEGER NOT NULL DEFAULT 1
)''',
      'CREATE UNIQUE INDEX idx_answer_log_q_day ON answer_log(question_id, day)',
      'CREATE INDEX idx_answer_log_day ON answer_log(day)',
      'CREATE INDEX idx_answer_log_workbook ON answer_log(workbook_id)',
    ],
  ),
  Migration(
    version: 8,
    note:
        '作答记录加「来源」（2026-10-26，用户第 9/16 条）：\n'
        '1) 加 origin / origin_title 两列：origin ∈ workbook(原卷) / set(组卷重刷) / redo(单题重刷)，'
        'origin_title 记组卷名。\n'
        '2) 唯一索引从 (question_id, day) 改成 (question_id, day, origin)：'
        '用户要求"重刷单独计一次"——同一天同一题，原卷做一次、组卷再刷一次，算两次。\n'
        '3) 旧行自动 origin=\'workbook\'，不影响历史统计。',
    statements: <String>[
      "ALTER TABLE answer_log ADD COLUMN origin TEXT NOT NULL DEFAULT 'workbook'",
      "ALTER TABLE answer_log ADD COLUMN origin_title TEXT NOT NULL DEFAULT ''",
      'DROP INDEX idx_answer_log_q_day',
      'CREATE UNIQUE INDEX idx_answer_log_q_day_origin ON answer_log(question_id, day, origin)',
      'CREATE INDEX idx_answer_log_origin ON answer_log(origin)',
    ],
  ),
  Migration(
    version: 9,
    note:
        '重刷独立 attempt（2026-10-26 用户：多次重刷要能逐次查看）：\n'
        '1) answer_log 加 attempt_id：一次重刷（组卷 run 也算一次）一个 id，'
        '同一天同一题刷两次会留两行，时间线才能打开"那一次"的笔迹。\n'
        '2) 唯一索引改 (question_id, day, origin, attempt_id)：原卷行 attempt_id=\'\'，'
        '重刷行带 run id，二者互不覆盖。\n'
        '3) 旧行 attempt_id=\'\'，归为"旧版重刷"，仍可显示。',
    statements: <String>[
      "ALTER TABLE answer_log ADD COLUMN attempt_id TEXT NOT NULL DEFAULT ''",
      "ALTER TABLE answer_log ADD COLUMN favorite_id TEXT NOT NULL DEFAULT ''",
      'DROP INDEX idx_answer_log_q_day_origin',
      'CREATE UNIQUE INDEX idx_answer_log_q_day_origin_attempt ON answer_log(question_id, day, origin, attempt_id)',
      'CREATE INDEX idx_answer_log_attempt ON answer_log(attempt_id)',
    ],
  ),
];

/// 数据库最终版本号。
int get kDatabaseVersion => kMigrations.last.version;

/// 取 [fromVersion]（不含）到 [toVersion]（含）之间要执行的语句，按版本升序摊平。
List<String> statementsBetween({
  required int fromVersion,
  required int toVersion,
}) {
  final List<String> result = <String>[];
  for (final Migration migration in kMigrations) {
    if (migration.version > fromVersion && migration.version <= toVersion) {
      result.addAll(migration.statements);
    }
  }
  return result;
}
