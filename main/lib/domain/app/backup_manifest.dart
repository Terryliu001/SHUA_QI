/// 备份包的**元信息契约**（纯 Dart）。
///
/// 为什么要单独放 domain：manifest 是**跨版本的数据契约**——
/// 备份文件里的这一段决定"这份备份能不能恢复到你这台机器上"。
/// 它不能依赖 sqflite / archive / 文件系统，否则没法在宿主机单测里钉住。
library;

/// 备份包里的 `manifest.json`。
class BackupManifest {
  const BackupManifest({
    required this.appVersion,
    required this.dbVersion,
    required this.createdAt,
    required this.workbooks,
    required this.favorites,
    required this.records,
  });

  factory BackupManifest.fromJson(Map<String, Object?> json) => BackupManifest(
    appVersion: (json['app_version'] as String?) ?? '',
    dbVersion: (json['db_version'] as num?)?.toInt() ?? 0,
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    workbooks: (json['workbooks'] as num?)?.toInt() ?? 0,
    favorites: (json['favorites'] as num?)?.toInt() ?? 0,
    records: (json['records'] as num?)?.toInt() ?? 0,
  );

  /// 导出时的应用版本号（给人看的）。
  final String appVersion;

  /// 导出时的**数据库版本**（迁移链的版本号）。
  ///
  /// 恢复时的硬约束：备份的版本比本机新 → 拒收。
  /// 本机更新（版本更老）→ 可以恢复，迁移会在下次打开库时自动跑。
  final int dbVersion;

  /// 导出时刻（毫秒）。
  final int createdAt;

  final int workbooks;
  final int favorites;
  final int records;

  /// `2026-10-26 12:30`
  String get createdText {
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(createdAt);
    return '${at.year}-${_two(at.month)}-${_two(at.day)} '
        '${_two(at.hour)}:${_two(at.minute)}';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'app_version': appVersion,
    'db_version': dbVersion,
    'created_at': createdAt,
    'workbooks': workbooks,
    'favorites': favorites,
    'records': records,
  };

  /// 这份备份能不能装进当前这台机器。
  ///
  /// [currentDbVersion] 是本机的库版本；备份比它新就**不能**恢复
  /// （老代码读不了新表结构，硬来会把数据写坏）。
  bool canRestoreOn(int currentDbVersion) => dbVersion <= currentDbVersion;

  static String _two(int value) => value.toString().padLeft(2, '0');
}
