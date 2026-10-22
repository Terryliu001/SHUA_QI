import 'dart:io';

/// spike 的落盘层。
///
/// **为什么要按候选目录挨个试**：`Directory.systemTemp` 在 Android 上不可靠
/// （本机实测落到 `/tmp`，应用无写权限，`create()` 直接抛异常），
/// 而 T0.2 不想为了一个一次性实验引入 path_provider。
/// 所以这里按「systemTemp → 应用私有 cache（两种路径别名）」依次尝试，第一个能建目录的胜出。
///
/// > 产品化（T2.4 SIF 落盘）必须换成 path_provider 的 `getApplicationSupportDirectory()`，
/// > 不允许把包名硬编码进产品代码。这里的硬编码只属于 spike。
///
/// 关键约束（INV-01）：所有方法都只在"抬笔 2 秒后"的 Timer 回调里被调用，
/// 绝不出现在 onPointerMove 的调用链上。
class SpikeStore {
  static const String _dirName = 'shuaqi_ink_spike';
  static const String _fileName = 'ink_spike.json';
  static const String _packageName = 'com.shuaqi.shuaqi';

  Directory? _resolvedDir;

  /// 解析出的落盘目录，未解析时为 null。
  String? get resolvedPath => _resolvedDir?.path;

  Future<String> save(String payload) async {
    final Directory dir = await _dir();
    final File file = File('${dir.path}/$_fileName');
    await file.writeAsString(payload, flush: true);
    return file.path;
  }

  /// 没有文件时返回 null。
  Future<String?> load() async {
    final Directory dir = await _dir();
    final File file = File('${dir.path}/$_fileName');
    try {
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> clear() async {
    final Directory dir = await _dir();
    final File file = File('${dir.path}/$_fileName');
    try {
      await file.delete();
    } on FileSystemException {
      // 本来就不存在，无所谓。
    }
  }

  Future<Directory> _dir() async {
    final Directory? cached = _resolvedDir;
    if (cached != null) {
      return cached;
    }
    final List<String> candidates = <String>[
      '${Directory.systemTemp.path}/$_dirName',
      '/data/user/0/$_packageName/cache/$_dirName',
      '/data/data/$_packageName/cache/$_dirName',
      Directory.current.path,
    ];
    Object? lastError;
    for (final String candidate in candidates) {
      try {
        final Directory dir = await Directory(candidate).create(recursive: true);
        _resolvedDir = dir;
        return dir;
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw FileSystemException('找不到可写的落盘目录（最后错误：$lastError）');
  }
}
