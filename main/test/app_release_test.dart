import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/app/app_release.dart';

void main() {
  test('版本号解析与比较：v 前缀、+build、多位数字', () {
    expect(
      AppVersion.tryParse('v0.1.3')!.compareTo(AppVersion.tryParse('0.1.2')!),
      greaterThan(0),
    );
    expect(
      AppVersion.tryParse('0.1.10')!.compareTo(AppVersion.tryParse('0.1.9')!),
      greaterThan(0),
    );
    expect(
      AppVersion.tryParse('0.2.0')!.compareTo(AppVersion.tryParse('0.1.99')!),
      greaterThan(0),
    );
    expect(
      AppVersion.tryParse('0.1.3+4')!.compareTo(AppVersion.tryParse('0.1.3')!),
      0,
    );
    expect(
      AppVersion.tryParse('0.1.3-beta')!
          .compareTo(AppVersion.tryParse('0.1.3')!),
      0,
    );
    expect(AppVersion.tryParse('v0.1.3')!.isNewerThan('0.1.2'), isTrue);
    expect(AppVersion.tryParse('v0.1.3')!.isNewerThan('0.1.3'), isFalse);
  });

  test('GitHub Release JSON：选 APK、取 digest、版本去 v', () {
    final AppRelease release = AppRelease.fromGitHubJson(<String, Object?>{
      'tag_name': 'v0.1.4',
      'name': '刷起 SHUAQI v0.1.4',
      'body': '更新内容',
      'html_url': 'https://github.com/Terryliu001/SHUA_QI/releases/tag/v0.1.4',
      'published_at': '2026-10-30T10:00:00Z',
      'assets': <Object?>[
        <String, Object?>{'name': 'notes.txt', 'size': 10},
        <String, Object?>{
          'name': 'shuaqi-0.1.4.apk',
          'size': 38500000,
          'browser_download_url': 'https://example.com/shuaqi-0.1.4.apk',
          'digest': 'sha256:abc',
        },
      ],
    });
    expect(release.version, '0.1.4');
    expect(release.tag, 'v0.1.4');
    expect(release.hasApk, isTrue);
    expect(release.apkSize, 38500000);
    expect(release.apkDigest, 'sha256:abc');
    expect(release.isNewerThan('0.1.3'), isTrue);
  });

  test('本地持久化 JSON 往返', () {
    final AppRelease release = AppRelease.fromGitHubJson(<String, Object?>{
      'tag_name': 'v0.1.4',
      'name': 'v0.1.4',
      'body': 'notes',
      'html_url': 'https://example.com',
      'published_at': '2026-10-30T10:00:00Z',
      'assets': <Object?>[
        <String, Object?>{
          'name': 'shuaqi-0.1.4.apk',
          'size': 1,
          'browser_download_url': 'https://example.com/a.apk',
        },
      ],
    });
    final AppRelease? back = AppRelease.fromJsonString(release.toJsonString());
    expect(back, isNotNull);
    expect(back!.version, '0.1.4');
    expect(back.apkUrl, 'https://example.com/a.apk');
    expect(back.toStorageJson()['apk_size'], 1);
  });

  test('没有 APK 的 Release：hasApk=false，不会提示可更新', () {
    final AppRelease release = AppRelease.fromGitHubJson(<String, Object?>{
      'tag_name': 'v0.1.4',
      'assets': <Object?>[],
    });
    expect(release.hasApk, isFalse);
    expect(release.isNewerThan('0.1.3'), isTrue);
  });
}
