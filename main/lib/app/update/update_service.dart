import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shuaqi/domain/app/app_release.dart';
import 'package:shuaqi/infra/platform/media_store_channel.dart';
import 'package:shuaqi/infra/update/github_release_client.dart';

/// 用户取消下载时抛这个，让 UI 区分「失败」和「我自己取消的」。
class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

/// 更新下载/校验/安装（0.1.3）。
///
/// 检查走 [GitHubReleaseClient]；下载到应用私有 `update/`，校验大小与 SHA-256
/// （GitHub asset 有 digest 时）；安装交给原生 `installApk`。
class UpdateService {
  const UpdateService({
    required this.supportPath,
    required this.channel,
    this.client = const GitHubReleaseClient(),
  });

  final String supportPath;
  final MediaStoreChannel channel;
  final GitHubReleaseClient client;

  Directory get _dir => Directory(p.join(supportPath, 'update'));

  Future<AppRelease?> check() => client.fetchLatest();

  /// 下载 APK；[onProgress] 会持续回调（received, total）。
  ///
  /// [isCancelled] 返回 true 时删除半截文件并抛 [UpdateCancelled]。
  Future<File> download(
    AppRelease release, {
    required void Function(int received, int total) onProgress,
    required bool Function() isCancelled,
  }) async {
    if (!release.hasApk) {
      throw const UpdateCheckException('这个版本没有可下载的 APK');
    }
    final Directory dir = _dir;
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final String safeVersion = release.version.replaceAll(
      RegExp(r'[^0-9A-Za-z._-]'),
      '_',
    );
    final File target = File(p.join(dir.path, 'shuaqi-$safeVersion.apk'));
    if (target.existsSync()) {
      await target.delete();
    }
    final HttpClient http = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    bool completed = false;
    try {
      final HttpClientRequest request = await http
          .getUrl(Uri.parse(release.apkUrl))
          .timeout(const Duration(seconds: 25));
      request.headers.set(HttpHeaders.userAgentHeader, 'SHUAQI-Android/0.1.3');
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw UpdateCheckException('下载失败：服务器返回 ${response.statusCode}');
      }
      final int total = response.contentLength > 0
          ? response.contentLength
          : release.apkSize;
      sink = target.openWrite();
      final _DigestSink digestSink = _DigestSink();
      final ByteConversionSink hasher = sha256.startChunkedConversion(
        digestSink,
      );
      int received = 0;
      int lastReported = 0;
      await for (final List<int> chunk in response) {
        if (isCancelled()) {
          throw const UpdateCancelled();
        }
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        // 每 256KB 报一次进度，避免 36MB 下载触发几千次 UI 重建。
        if (received - lastReported >= 256 * 1024 ||
            (total > 0 && received >= total)) {
          lastReported = received;
          onProgress(received, total);
        }
      }
      hasher.close();
      await sink.flush();
      await sink.close();
      sink = null;
      if (total > 0 && received != total) {
        throw UpdateCheckException('下载不完整（$received/$total 字节），请重试');
      }
      final String expected = release.apkDigest.toLowerCase();
      if (expected.startsWith('sha256:')) {
        final String actual = digestSink.value?.toString() ?? '';
        if (actual.isNotEmpty && actual != expected.substring(7)) {
          throw const UpdateCheckException('安装包校验失败（SHA-256 不一致）');
        }
      }
      completed = true;
      return target;
    } on UpdateCancelled {
      rethrow;
    } on UpdateCheckException {
      rethrow;
    } on TimeoutException {
      throw const UpdateCheckException('下载超时，请确认网络后重试');
    } on SocketException {
      throw const UpdateCheckException('下载中断，请确认网络后重试');
    } on Object catch (error) {
      throw UpdateCheckException('下载失败：$error');
    } finally {
      http.close(force: true);
      if (sink != null) {
        try {
          await sink.close();
        } on Object {
          // 忽略关闭半截文件的异常。
        }
      }
      if (!completed && target.existsSync()) {
        try {
          await target.delete();
        } on Object {
          // 删不掉不影响下次下载（会被覆盖）。
        }
      }
    }
  }

  Future<bool> canInstallApk() => channel.canInstallApk();

  Future<bool> installApk(File file) => channel.installApk(file.path);

  Future<void> openUnknownSourcesSettings() =>
      channel.openUnknownSourcesSettings();

  /// 清理旧安装包（保留 [keepPath]；没有就全删）。
  Future<void> cleanupOldApks({String? keepPath}) async {
    final Directory dir = _dir;
    if (!dir.existsSync()) {
      return;
    }
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is File &&
          entity.path.toLowerCase().endsWith('.apk') &&
          entity.path != keepPath) {
        try {
          await entity.delete();
        } on Object {
          // 删不掉不影响下次更新。
        }
      }
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
