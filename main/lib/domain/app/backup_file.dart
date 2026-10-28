import 'package:shuaqi/domain/app/backup_naming.dart';

/// 一份备份文件（列表/管理用，0.1.3）。
///
/// Android 10+ 的备份在 MediaStore Downloads 里，只有 `uri`；
/// Android 8/9 的兜底目录在应用外部目录，只有 `path`。两者至少有一个。
class BackupFileInfo {
  const BackupFileInfo({
    this.uri = '',
    this.path = '',
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
    this.owned = true,
  });

  factory BackupFileInfo.fromJson(Map<String, Object?> json) {
    final String name = (json['name'] as String?) ?? '';
    return BackupFileInfo(
      uri: (json['uri'] as String?) ?? '',
      path: (json['path'] as String?) ?? '',
      name: name,
      sizeBytes: (json['size'] as num?)?.toInt() ?? 0,
      modifiedAt: (json['modified'] as num?)?.toInt() ?? 0,
      owned: (json['owned'] as bool?) ?? true,
    );
  }

  final String uri;
  final String path;
  final String name;
  final int sizeBytes;

  /// 修改时间（UTC 毫秒）。
  final int modifiedAt;

  /// 是否是本应用创建的（系统不允许管理别人的文件）。
  final bool owned;

  String get id => uri.isNotEmpty ? uri : path;

  bool get exists => id.isNotEmpty;

  bool get isBeforeUpdate => isBeforeUpdateBackupName(name);

  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(modifiedAt);

  BackupFileInfo copyWith({String? name}) => BackupFileInfo(
    uri: uri,
    path: path,
    name: name ?? this.name,
    sizeBytes: sizeBytes,
    modifiedAt: modifiedAt,
    owned: owned,
  );
}
