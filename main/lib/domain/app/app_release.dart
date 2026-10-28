import 'dart:convert';

/// 版本号与 GitHub Release（0.1.3）。
///
/// 为什么不引 package_info_plus / semver：
/// - `AppInfo.version` 是项目唯一的版本定义点，更新检查只需要读它；
/// - 版本比较只支持 `major.minor.patch`（可带 `v`、`+build`、`-beta`），
///   几十行纯 Dart 足够，避免为一行比较新增依赖。
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static AppVersion? tryParse(String raw) {
    String text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    // 去掉 +build 与 -prerelease。
    final int plus = text.indexOf('+');
    if (plus >= 0) {
      text = text.substring(0, plus);
    }
    final int dash = text.indexOf('-');
    if (dash >= 0) {
      text = text.substring(0, dash);
    }
    final List<String> parts = text.split('.');
    if (parts.isEmpty) {
      return null;
    }
    final int major = int.tryParse(parts[0]) ?? 0;
    final int minor = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final int patch = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
    return AppVersion(major, minor, patch);
  }

  bool isNewerThan(String current) {
    final AppVersion? other = tryParse(current);
    if (other == null) {
      return false;
    }
    return compareTo(other) > 0;
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) {
      return major.compareTo(other.major);
    }
    if (minor != other.minor) {
      return minor.compareTo(other.minor);
    }
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => '$major.$minor.$patch';

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);
}

/// 一次 GitHub Release 检查的结果。
class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.name,
    required this.notes,
    required this.publishedAt,
    required this.htmlUrl,
    required this.apkUrl,
    required this.apkSize,
    this.apkDigest = '',
  });

  /// 解析 GitHub `releases/latest` 的 JSON。
  factory AppRelease.fromGitHubJson(Map<String, Object?> json) {
    final String tag = (json['tag_name'] as String?) ?? '';
    final String name = (json['name'] as String?) ?? tag;
    final String body = (json['body'] as String?) ?? '';
    final String htmlUrl = (json['html_url'] as String?) ?? '';
    final String published = (json['published_at'] as String?) ?? '';
    final DateTime? publishedAt = DateTime.tryParse(published)?.toLocal();

    String apkUrl = '';
    int apkSize = 0;
    String digest = '';
    final Object? assets = json['assets'];
    if (assets is List) {
      for (final Object? item in assets) {
        if (item is! Map) {
          continue;
        }
        final Map<String, Object?> asset = item.cast<String, Object?>();
        final String assetName = (asset['name'] as String?) ?? '';
        if (!assetName.toLowerCase().endsWith('.apk')) {
          continue;
        }
        // 只发一个 arm64 包；若将来多 ABI，优先带 arm64 的那个。
        if (apkUrl.isNotEmpty && !assetName.toLowerCase().contains('arm64')) {
          continue;
        }
        apkUrl = (asset['browser_download_url'] as String?) ?? '';
        apkSize = (asset['size'] as num?)?.toInt() ?? 0;
        digest = (asset['digest'] as String?) ?? '';
        if (assetName.toLowerCase().contains('arm64')) {
          break;
        }
      }
    }
    return AppRelease(
      version: _versionText(tag),
      tag: tag,
      name: name.isEmpty ? tag : name,
      notes: body,
      publishedAt: publishedAt?.millisecondsSinceEpoch ?? 0,
      htmlUrl: htmlUrl,
      apkUrl: apkUrl,
      apkSize: apkSize,
      apkDigest: digest,
    );
  }

  /// 自己持久化用的 JSON（字段比 GitHub 原 JSON 少，恢复时不再依赖网络结构）。
  factory AppRelease.fromStorageJson(Map<String, Object?> json) {
    return AppRelease(
      version: (json['version'] as String?) ?? '',
      tag: (json['tag'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      notes: (json['notes'] as String?) ?? '',
      publishedAt: (json['published_at'] as num?)?.toInt() ?? 0,
      htmlUrl: (json['html_url'] as String?) ?? '',
      apkUrl: (json['apk_url'] as String?) ?? '',
      apkSize: (json['apk_size'] as num?)?.toInt() ?? 0,
      apkDigest: (json['apk_digest'] as String?) ?? '',
    );
  }

  final String version;
  final String tag;
  final String name;
  final String notes;
  final int publishedAt;
  final String htmlUrl;
  final String apkUrl;
  final int apkSize;
  final String apkDigest;

  bool get hasApk => apkUrl.isNotEmpty;

  bool isNewerThan(String current) {
    final AppVersion? mine = AppVersion.tryParse(version);
    return mine != null && mine.isNewerThan(current);
  }

  Map<String, Object?> toStorageJson() => <String, Object?>{
    'version': version,
    'tag': tag,
    'name': name,
    'notes': notes,
    'published_at': publishedAt,
    'html_url': htmlUrl,
    'apk_url': apkUrl,
    'apk_size': apkSize,
    'apk_digest': apkDigest,
  };

  String toJsonString() => jsonEncode(toStorageJson());

  static AppRelease? fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        return AppRelease.fromStorageJson(decoded.cast<String, Object?>());
      }
    } on Object {
      // 坏缓存当没有；下次检查会重写。
    }
    return null;
  }

  static String _versionText(String tag) {
    String text = tag.trim();
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    final int plus = text.indexOf('+');
    if (plus >= 0) {
      text = text.substring(0, plus);
    }
    return text;
  }
}
