/// 备份文件命名与展示用的纯函数（0.1.3）。
///
/// 备份名是**用户能看懂、能排序、能看出用途**的字符串：
/// - 手动导出：`SHUAQI_backup_20261028-1345.zip`
/// - 更新前自动备份：`SHUAQI_backup_before_v0.1.3_20261028-1345.zip`
///
/// 这里只做字符串处理，不碰文件系统，方便单测。
library;

/// 手动导出的默认名（不含 `.zip`）。
String defaultBackupBaseName(DateTime now) {
  return 'SHUAQI_backup_${_stamp(now)}';
}

/// 更新前自动备份的默认名（不含 `.zip`）。
String beforeUpdateBackupBaseName({
  required String targetVersion,
  required DateTime now,
}) {
  final String version = targetVersion.trim().replaceAll(
    RegExp(r'[^0-9A-Za-z._-]'),
    '',
  );
  return 'SHUAQI_backup_before_v${version.isEmpty ? 'next' : version}_'
      '${_stamp(now)}';
}

/// 把用户输入清成一个可用的文件名（不含扩展名）。
///
/// 允许中文/空格/连字符；去掉路径分隔符与 Windows 非法字符；
/// 去掉用户自己输入的 `.zip`；截到 80 字符，避免 MediaStore 截断。
String sanitizeBackupBaseName(String raw) {
  String name = raw.trim();
  name = name.replaceFirst(RegExp(r'\.zip$', caseSensitive: false), '');
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (name.length > 80) {
    name = name.substring(0, 80).trim();
  }
  return name;
}

/// 校验用户输入的备份名（不含扩展名）。
bool isValidBackupBaseName(String raw) {
  final String name = sanitizeBackupBaseName(raw);
  if (name.isEmpty) {
    return false;
  }
  // 避免只剩一堆下划线/点。
  if (name.replaceAll(RegExp(r'[._\s-]'), '').isEmpty) {
    return false;
  }
  return true;
}

/// 强制补 `.zip`（大小写不敏感，已存在就不重复加）。
String ensureZipName(String name) {
  final String trimmed = name.trim();
  if (trimmed.toLowerCase().endsWith('.zip')) {
    return trimmed;
  }
  return '$trimmed.zip';
}

/// 是不是「更新前备份」。
bool isBeforeUpdateBackupName(String name) {
  return name.toLowerCase().contains('_before_v');
}

/// 重名时追加 `-2`、`-3`…；[existing] 是现有文件名集合（含 `.zip`）。
String dedupeBackupName(String base, Set<String> existing) {
  final Set<String> lower = <String>{
    for (final String name in existing) name.toLowerCase(),
  };
  String candidate = '$base.zip';
  if (!lower.contains(candidate.toLowerCase())) {
    return candidate;
  }
  for (int i = 2; i < 1000; i += 1) {
    candidate = '$base-$i.zip';
    if (!lower.contains(candidate.toLowerCase())) {
      return candidate;
    }
  }
  return '$base-${DateTime.now().millisecondsSinceEpoch}.zip';
}

/// 从完整文件名反推可编辑的基名（去掉 `.zip`）。
String backupBaseNameOf(String fileName) {
  return fileName.replaceFirst(RegExp(r'\.zip$', caseSensitive: false), '');
}

String _stamp(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}${two(at.month)}${two(at.day)}-'
      '${two(at.hour)}${two(at.minute)}';
}
