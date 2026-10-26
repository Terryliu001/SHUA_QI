import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shuaqi/app/records/record_service.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/domain/model/answer_sheet.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/records/answer_log.dart';
import 'package:shuaqi/infra/db/app_database.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 历史作答记录回填（阶段 9，一次性）。
///
/// ## 为什么必须做
/// 事件表是本轮才建的，用户的既有作答全在文件里。不回填的话，记录页
/// 第一天是空的，"连续打卡"从 0 开始——对已经在用的人不公平。
///
/// ## 只回填"有证据"的
/// 三类证据，各自的语义不同（都写进日志，别混）：
/// 1. `answer_sheet.v1.json` 的 `updated_at` → 调过作答框/识别过，**算作答**；
/// 2. `sessions/<sid>/answers/<qid>.sif` 的 mtime → 真写了笔迹，**算作答**；
/// 3. `grading.v1.json` 里 `verdict != none` 的 `at` → 判过，**算作答**（用户口径：
///    "有判题也算"）。注意 `verdict == none` 的行是一次批量改卷写下的，
///    把它算进来会给一天凭空造出几十道题。
///
/// ## 卷被删了怎么办
/// 删卷会连 `workbooks/<id>/` 整棵删掉，那些证据已经不存在了，回填不出来；
/// 但**从这次起**，记录独立成表、不设外键，以后再删卷，历史不会跟着消失。
/// 回填口径版本。改了口径就 +1，已装机的用户会在下次启动重跑一次
/// （`seed` 幂等：已有的行只补更完整的结论，不会重复计数）。
///
/// 1 → 2：修掉"insert(ignore) 返回旧行号导致判题结论丢失"的 bug 后重跑一次。
const String kBackfillVersion = '2';

Future<int> backfillAnswerLog({
  required AppDatabase db,
  required Vault vault,
  required LayoutStore layout,
  required RecordService records,
}) async {
  final SettingDao settings = SettingDao(db.raw);
  final String? done = await settings.get(AppSettingKeys.recordsBackfilled);
  if (done == kBackfillVersion) {
    return 0;
  }

  int seeded = 0;
  try {
    final List<Workbook> workbooks = await WorkbookDao(
      db.raw,
    ).listByRecent(limit: 100000);

    for (final Workbook workbook in workbooks) {
      seeded += await _backfillWorkbook(
        workbook: workbook,
        vault: vault,
        layout: layout,
        records: records,
      );
    }
  } on Object catch (error) {
    // 回填失败不阻断启动：下次启动会再来一次（标记写在最后）。
    debugPrint('作答记录回填中止：$error');
    return seeded;
  }

  await settings.put(AppSettingKeys.recordsBackfilled, kBackfillVersion);
  debugPrint('作答记录回填完成：$seeded 条');
  return seeded;
}

Future<int> _backfillWorkbook({
  required Workbook workbook,
  required Vault vault,
  required LayoutStore layout,
  required RecordService records,
}) async {
  final Set<String> seen = <String>{};
  int count = 0;

  Future<void> seed(
    String questionId,
    int at,
    RecordSource source,
    AnswerVerdict verdict,
  ) async {
    if (questionId.isEmpty || at <= 0) {
      return;
    }
    final String key = '$questionId|$at|${verdict.name}';
    if (!seen.add(key)) {
      return;
    }
    await records.seed(
      workbookId: workbook.id,
      questionId: questionId,
      at: at,
      source: source,
      verdict: verdict,
    );
    count += 1;
  }

  // 1. 作答框（调过框 / 识别过）。
  try {
    final Map<String, Object?>? json = await layout.readAnswerSheet(workbook.id);
    final AnswerSheetData sheet = AnswerSheetData.fromJson(json);
    for (final AnswerSheetEntry entry in sheet.entries.values) {
      await seed(entry.questionId, entry.updatedAt, RecordSource.save, AnswerVerdict.none);
    }
  } on Object catch (error) {
    debugPrint('回填 ${workbook.id} 作答框失败：$error');
  }

  // 2. 答题卡笔迹文件（真写了字）。mtime 就是最后落盘时间。
  try {
    final Directory sessions = vault.dir(VaultPaths.sessionsRoot(workbook.id));
    if (sessions.existsSync()) {
      await for (final FileSystemEntity sessionEntity in sessions.list()) {
        if (sessionEntity is! Directory) {
          continue;
        }
        final Directory answers = Directory(p.join(sessionEntity.path, 'answers'));
        if (!answers.existsSync()) {
          continue;
        }
        await for (final FileSystemEntity file in answers.list()) {
          if (file is! File) {
            continue;
          }
          final String name = p.basename(file.path);
          if (!name.endsWith('.sif')) {
            continue;
          }
          final String questionId = _questionIdOfSif(name);
          final int at = file.statSync().modified.millisecondsSinceEpoch;
          await seed(questionId, at, RecordSource.ink, AnswerVerdict.none);
        }
      }
    }
  } on Object catch (error) {
    debugPrint('回填 ${workbook.id} 笔迹失败：$error');
  }

  // 3. 判题结论（只取 nonce，批量改卷写的 none 不算作答）。
  try {
    final GradingData grading = GradingData.fromJson(
      await layout.readGrading(workbook.id),
    );
    for (final QuestionGrade grade in grading.grades.values) {
      if (grade.verdict == AnswerVerdict.none) {
        continue;
      }
      await seed(grade.questionId, grade.at, RecordSource.grade, grade.verdict);
    }
  } on Object catch (error) {
    debugPrint('回填 ${workbook.id} 判题失败：$error');
  }

  return count;
}

/// `06GQ5BAE....sif` → 题目 id；`<qid>_p1.sif` → 去掉纸张序号。
///
/// 题目 id 是 ULID（大写字母 + 数字），不含下划线，所以按第一个 `_p<数字>` 切是安全的。
String _questionIdOfSif(String fileName) {
  String base = fileName.substring(0, fileName.length - '.sif'.length);
  final int mark = base.lastIndexOf('_p');
  if (mark > 0) {
    final String suffix = base.substring(mark + 2);
    if (suffix.isNotEmpty && int.tryParse(suffix) != null) {
      base = base.substring(0, mark);
    }
  }
  return base;
}
