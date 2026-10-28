import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/app/backup/backup_service.dart';
import 'package:shuaqi/app/update/update_service.dart';
import 'package:shuaqi/domain/app/app_release.dart';
import 'package:shuaqi/domain/app/backup_naming.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/settings_providers.dart';

/// 更新检查/下载/安装的界面状态。
class UpdateState {
  const UpdateState({
    this.checking = false,
    this.latest,
    this.error,
    this.lastCheckedAt = 0,
    this.seenVersion = '',
    this.downloading = false,
    this.downloaded = 0,
    this.totalBytes = 0,
    this.downloadedPath,
    this.installing = false,
    this.backingUp = false,
    this.lastBackupName = '',
    this.lastBackupUri = '',
    this.lastBackupAt = 0,
  });

  final bool checking;
  final AppRelease? latest;
  final String? error;
  final int lastCheckedAt;
  final String seenVersion;
  final bool downloading;
  final int downloaded;
  final int totalBytes;
  final String? downloadedPath;
  final bool installing;
  final bool backingUp;
  final String lastBackupName;
  final String lastBackupUri;
  final int lastBackupAt;

  bool get hasUpdate =>
      latest != null && latest!.hasApk && latest!.isNewerThan(AppInfo.version);

  bool get hasUnseenUpdate => hasUpdate && latest!.version != seenVersion;

  double get downloadProgress {
    if (totalBytes <= 0) {
      return 0;
    }
    return (downloaded / totalBytes).clamp(0.0, 1.0).toDouble();
  }

  bool get busy => checking || downloading || installing || backingUp;

  UpdateState copyWith({
    bool? checking,
    AppRelease? latest,
    bool clearLatest = false,
    String? error,
    bool clearError = false,
    int? lastCheckedAt,
    String? seenVersion,
    bool? downloading,
    int? downloaded,
    int? totalBytes,
    String? downloadedPath,
    bool clearDownloaded = false,
    bool? installing,
    bool? backingUp,
    String? lastBackupName,
    String? lastBackupUri,
    int? lastBackupAt,
  }) {
    return UpdateState(
      checking: checking ?? this.checking,
      latest: clearLatest ? null : (latest ?? this.latest),
      error: clearError ? null : (error ?? this.error),
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      seenVersion: seenVersion ?? this.seenVersion,
      downloading: downloading ?? this.downloading,
      downloaded: downloaded ?? this.downloaded,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedPath: clearDownloaded
          ? null
          : (downloadedPath ?? this.downloadedPath),
      installing: installing ?? this.installing,
      backingUp: backingUp ?? this.backingUp,
      lastBackupName: lastBackupName ?? this.lastBackupName,
      lastBackupUri: lastBackupUri ?? this.lastBackupUri,
      lastBackupAt: lastBackupAt ?? this.lastBackupAt,
    );
  }
}

/// 更新服务（检查 + 下载 + 安装）。
final Provider<UpdateService> updateServiceProvider = Provider<UpdateService>((
  Ref ref,
) {
  final deps = ref.watch(appDependenciesProvider);
  return UpdateService(
    supportPath: deps.supportPath,
    channel: ref.watch(mediaStoreChannelProvider),
  );
});

/// 更新状态（设置页红点、版本说明页都看它）。
final NotifierProvider<UpdateController, UpdateState> updateProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

/// 设置 tab / 版本说明行的小红点。
final Provider<bool> updateBadgeProvider = Provider<bool>((Ref ref) {
  return ref.watch(updateProvider).hasUnseenUpdate;
});

class UpdateController extends Notifier<UpdateState> {
  late final SettingDao _dao;
  late final UpdateService _service;
  bool _loaded = false;
  bool _cancelDownload = false;

  @override
  UpdateState build() {
    _dao = SettingDao(ref.watch(appDependenciesProvider).db.raw);
    _service = ref.watch(updateServiceProvider);
    unawaited(_load());
    return const UpdateState();
  }

  Future<void> _load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final int lastCheck =
          int.tryParse(
            await _dao.get(AppSettingKeys.updateLastCheckAt) ?? '',
          ) ??
          0;
      final String seen =
          await _dao.get(AppSettingKeys.updateSeenVersion) ?? '';
      final AppRelease? latest = AppRelease.fromJsonString(
        await _dao.get(AppSettingKeys.updateLatestJson),
      );
      final String backupName =
          await _dao.get(AppSettingKeys.updateLastBackupName) ?? '';
      final String backupUri =
          await _dao.get(AppSettingKeys.updateLastBackupUri) ?? '';
      final int backupAt =
          int.tryParse(
            await _dao.get(AppSettingKeys.updateLastBackupAt) ?? '',
          ) ??
          0;
      state = state.copyWith(
        latest: latest,
        lastCheckedAt: lastCheck,
        seenVersion: seen,
        lastBackupName: backupName,
        lastBackupUri: backupUri,
        lastBackupAt: backupAt,
      );
    } on Object {
      // 读不到就按"没检查过"处理。
    }
  }

  /// 手动检查（版本说明页按钮）。
  Future<void> checkNow() => _check(manual: true);

  /// 启动/回前台/定时器调用：距上次检查不足 6 小时就跳过。
  Future<void> checkIfDue({bool force = false}) async {
    if (state.checking || state.backingUp || state.downloading) {
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        state.lastCheckedAt > 0 &&
        now - state.lastCheckedAt < const Duration(hours: 6).inMilliseconds) {
      return;
    }
    await _check(manual: false);
  }

  Future<void> _check({required bool manual}) async {
    if (state.checking || state.backingUp || state.downloading) {
      return;
    }
    state = state.copyWith(checking: true, clearError: true);
    try {
      final AppRelease? latest = await _service.check();
      final int now = DateTime.now().millisecondsSinceEpoch;
      state = state.copyWith(
        checking: false,
        latest: latest,
        clearLatest: latest == null,
        lastCheckedAt: now,
      );
      await _dao.put(AppSettingKeys.updateLastCheckAt, '$now');
      if (latest == null) {
        await _dao.remove(AppSettingKeys.updateLatestJson);
      } else {
        await _dao.put(AppSettingKeys.updateLatestJson, latest.toJsonString());
      }
    } on Object catch (error) {
      state = state.copyWith(checking: false, error: manual ? '$error' : null);
      if (manual) {
        rethrow;
      }
    }
  }

  /// 打开版本说明时调用：把当前最新版的"未读"标记清掉。
  Future<void> markSeen() async {
    final AppRelease? latest = state.latest;
    if (latest == null || !latest.isNewerThan(AppInfo.version)) {
      return;
    }
    state = state.copyWith(seenVersion: latest.version);
    await _dao.put(AppSettingKeys.updateSeenVersion, latest.version);
  }

  Future<void> openUnknownSources() => _service.openUnknownSourcesSettings();

  Future<void> cancelDownload() async {
    _cancelDownload = true;
  }

  /// 用户点「下载并安装」：先备份，再下载，再拉起安装器。
  Future<void> startUpdate() async {
    final AppRelease? latest = state.latest;
    if (latest == null || !latest.hasApk || state.busy) {
      return;
    }
    _cancelDownload = false;
    state = state.copyWith(
      backingUp: true,
      clearError: true,
      downloaded: 0,
      totalBytes: latest.apkSize,
      clearDownloaded: true,
    );
    try {
      // 1) 更新前自动备份（用户口径：备份失败就中止）。
      final BackupService backup = ref.read(backupServiceProvider);
      final String base = beforeUpdateBackupBaseName(
        targetVersion: latest.version,
        now: DateTime.now(),
      );
      final BackupFile file = await backup.createBackup(name: base);
      final String? uri = await ref
          .read(mediaStoreChannelProvider)
          .saveFile(path: file.path, name: file.name);
      final int now = DateTime.now().millisecondsSinceEpoch;
      state = state.copyWith(
        backingUp: false,
        lastBackupName: file.name,
        lastBackupUri: uri ?? '',
        lastBackupAt: now,
      );
      await _dao.put(AppSettingKeys.updateLastBackupName, file.name);
      await _dao.put(AppSettingKeys.updateLastBackupUri, uri ?? '');
      await _dao.put(AppSettingKeys.updateLastBackupAt, '$now');
      // 临时文件交给系统保存后即可删除。
      try {
        await File(file.path).delete();
      } on Object {
        // 删除失败不影响更新。
      }

      // 2) 下载。
      state = state.copyWith(downloading: true);
      final File apk = await _service.download(
        latest,
        onProgress: (int received, int total) {
          state = state.copyWith(
            downloaded: received,
            totalBytes: total > 0 ? total : latest.apkSize,
          );
        },
        isCancelled: () => _cancelDownload,
      );
      state = state.copyWith(downloading: false, downloadedPath: apk.path);

      // 3) 安装。
      final bool canInstall = await _service.canInstallApk();
      if (!canInstall) {
        state = state.copyWith(error: '请先允许本应用「安装未知应用」，再点一次安装');
        return;
      }
      state = state.copyWith(installing: true);
      await _service.installApk(apk);
      state = state.copyWith(installing: false);
    } on UpdateCancelled {
      state = state.copyWith(
        downloading: false,
        backingUp: false,
        installing: false,
      );
    } on Object catch (error) {
      state = state.copyWith(
        backingUp: false,
        downloading: false,
        installing: false,
        error: '$error',
      );
    }
  }

  Future<void> installDownloaded() async {
    final String? path = state.downloadedPath;
    if (path == null || state.installing) {
      return;
    }
    try {
      final bool canInstall = await _service.canInstallApk();
      if (!canInstall) {
        state = state.copyWith(error: '请先允许本应用「安装未知应用」，再点一次安装');
        return;
      }
      state = state.copyWith(installing: true, clearError: true);
      await _service.installApk(File(path));
      state = state.copyWith(installing: false);
    } on Object catch (error) {
      state = state.copyWith(installing: false, error: '$error');
    }
  }

  Future<void> clearError() async {
    state = state.copyWith(clearError: true);
  }
}
