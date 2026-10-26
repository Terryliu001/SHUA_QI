import 'dart:io';

/// 磁盘满/写失败的用户文案（纯 Dart，无 UI）。
///
/// ENOSPC 在 Android 上是 28，Windows 上是 112；
/// 有些 ROM 只给 `No space left on device` 字符串。这里统一翻成一句人话，
/// 避免把 `FileSystemException: ... errno = 28` 直接怼到用户脸上。
String storageErrorText(Object error) {
  if (_isFull(error)) {
    return '存储空间不足：请先清理缓存或删除不用的卷，再重试。';
  }
  return '操作失败：$error';
}

/// 带动作前缀的版本：导出/备份/导入各自说明"哪一步失败"。
String storageAwareMessage(String action, Object error) {
  if (_isFull(error)) {
    return '$action失败：存储空间不足，请先清理缓存或删除不用的卷。';
  }
  return '$action失败：$error';
}

bool _isFull(Object error) {
  if (error is FileSystemException) {
    final int? code = error.osError?.errorCode;
    final String detail = '${error.message} ${error.osError?.message ?? ''}';
    return code == 28 ||
        code == 112 ||
        detail.toLowerCase().contains('no space') ||
        detail.contains('磁盘空间') ||
        detail.contains('存储空间');
  }
  return false;
}
