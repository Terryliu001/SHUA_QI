import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shuaqi/domain/app/app_release.dart';

/// GitHub Releases 检查失败时给用户看的话。
class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// GitHub Releases API 的薄客户端（0.1.3）。
///
/// 只做一件事：拿 `releases/latest`，解析成 [AppRelease]。
/// 不带 token（仓库公开，更新检查不该把凭证编进 APK）。
///
/// 手测更新链路时可用 `--dart-define=UPDATE_API_BASE=http://...` 指向本地
/// 假源：此时请求 `$base/latest.json`，返回与 GitHub 同形状的 JSON。
class GitHubReleaseClient {
  const GitHubReleaseClient({
    this.owner = 'Terryliu001',
    this.repo = 'SHUA_QI',
    this.apiBaseOverride = const String.fromEnvironment('UPDATE_API_BASE'),
  });

  final String owner;
  final String repo;

  /// 空 = 走真实 GitHub；非空 = 本地/镜像测试源。
  final String apiBaseOverride;

  String get _url {
    if (apiBaseOverride.isNotEmpty) {
      final String base = apiBaseOverride.endsWith('/')
          ? apiBaseOverride.substring(0, apiBaseOverride.length - 1)
          : apiBaseOverride;
      return '$base/latest.json';
    }
    return 'https://api.github.com/repos/$owner/$repo/releases/latest';
  }

  Future<AppRelease?> fetchLatest() async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final HttpClientRequest request = await client
          .getUrl(Uri.parse(_url))
          .timeout(const Duration(seconds: 20));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'SHUAQI-Android/0.1.3');
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final String body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 25));
      if (response.statusCode == 404) {
        // 还没有任何 Release：不是错误，只是没有可更新的版本。
        return null;
      }
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const UpdateCheckException('GitHub 检查太频繁了（限流），过一会儿再试');
      }
      if (response.statusCode != 200) {
        throw UpdateCheckException('GitHub 返回 ${response.statusCode}，暂时查不到更新');
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const UpdateCheckException('更新信息格式不对');
      }
      return AppRelease.fromGitHubJson(decoded.cast<String, Object?>());
    } on TimeoutException {
      throw const UpdateCheckException('检查更新超时，请确认网络后重试');
    } on SocketException {
      throw const UpdateCheckException('连不上 GitHub，请确认网络后重试');
    } on HttpException {
      throw const UpdateCheckException('网络请求失败，请稍后重试');
    } on FormatException {
      throw const UpdateCheckException('更新信息解析失败');
    } finally {
      client.close(force: true);
    }
  }
}
