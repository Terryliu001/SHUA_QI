import 'dart:io';
import 'dart:typed_data';

import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/infra/db/app_database.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 个人空间的数据（昵称 / 格言 / 头像 / 封面）。
class ProfileData {
  const ProfileData({
    this.name = '',
    this.motto = '',
    this.hasAvatar = false,
    this.hasCover = false,
  });

  /// 昵称（≤ [ProfileStore.maxNameLength] 字）。空串 = 没设。
  final String name;

  /// 格言（≤ [ProfileStore.maxMottoLength] 字，可多行）。空串 = 没设。
  final String motto;

  final bool hasAvatar;

  /// 有没有自定义封面。false = 跟随主题底色（用户口径的"默认"）。
  final bool hasCover;

  ProfileData copyWith({
    String? name,
    String? motto,
    bool? hasAvatar,
    bool? hasCover,
  }) => ProfileData(
    name: name ?? this.name,
    motto: motto ?? this.motto,
    hasAvatar: hasAvatar ?? this.hasAvatar,
    hasCover: hasCover ?? this.hasCover,
  );
}

/// 个人空间的读写（阶段 9）。
///
/// ## 为什么图片放 Vault 而不是数据库
/// 头像是几 MB 的二进制，进 SQLite 会把库撑大、每次备份都复制一遍；
/// 放 `vault/profile/` 与卷/收藏同构，清理与导出都走同一套路径约定。
///
/// ## 为什么不重新编码图片
/// Flutter 没有内置 JPEG 编码器（只能编 PNG），重编码一张 12MP 照片会变成
/// 十几 MB 的 PNG，还掉画质。这里**原样收编**，解码时用 `cacheWidth`
/// 把内存压在目标尺寸（记录页的封面最多 1600px 宽）。
class ProfileStore {
  ProfileStore({required this.vault, required AppDatabase db})
    : _settings = SettingDao(db.raw);

  static const int maxNameLength = 12;
  static const int maxMottoLength = 120;

  final SettingDao _settings;
  final Vault vault;

  Future<ProfileData> load() async {
    final String name = (await _settings.get(AppSettingKeys.profileName)) ?? '';
    final String motto =
        (await _settings.get(AppSettingKeys.profileMotto)) ?? '';
    return ProfileData(
      name: name.trim(),
      motto: motto.trim(),
      hasAvatar: vault.exists(VaultPaths.profileAvatar()),
      hasCover: vault.exists(VaultPaths.profileCover()),
    );
  }

  Future<void> saveName(String raw) =>
      _settings.put(AppSettingKeys.profileName, _clamp(raw, maxNameLength));

  Future<void> saveMotto(String raw) =>
      _settings.put(AppSettingKeys.profileMotto, _clamp(raw, maxMottoLength));

  /// 收编一张头像原图（覆盖旧的）。
  Future<void> setAvatar(File source) async {
    await _replace(VaultPaths.profileAvatar(), source);
  }

  Future<void> setCover(File source) async {
    await _replace(VaultPaths.profileCover(), source);
  }

  /// 直接写裁剪后的字节（2026-10-26 用户第 3 条：选完图可以自己裁一块）。
  ///
  /// 与 [setAvatar] 的区别：那条是"原样收编用户挑的文件"（不重编码），
  /// 这条写的是**已经裁好的 PNG**。
  Future<void> setAvatarBytes(Uint8List bytes) async {
    await _replaceBytes(VaultPaths.profileAvatar(), bytes);
  }

  /// 封面同理（写裁剪后的 PNG）。
  Future<void> setCoverBytes(Uint8List bytes) async {
    await _replaceBytes(VaultPaths.profileCover(), bytes);
  }

  Future<void> clearAvatar() => _delete(VaultPaths.profileAvatar());

  Future<void> clearCover() => _delete(VaultPaths.profileCover());

  /// 绝对路径（UI 渲染用；不存在时返回的 File 也照样能构造，由 errorBuilder 兜底）。
  File avatarFile() => vault.file(VaultPaths.profileAvatar());

  File coverFile() => vault.file(VaultPaths.profileCover());

  Future<void> _replace(String relative, File source) async {
    // 先删旧文件：Vault.adoptFile 的契约是"目标存在就拒绝覆盖"，
    // 这条规矩保护的是卷与笔迹，个人空间是我们自己主动要换图，先删再收编。
    final File target = vault.file(relative);
    if (target.existsSync()) {
      await target.delete();
    }
    await vault.adoptFile(relative, source);
  }

  /// 原子写字节（先写临时文件再 rename）。
  Future<void> _replaceBytes(String relative, Uint8List bytes) async {
    await vault.writeAtomically(relative, bytes);
  }

  Future<void> _delete(String relative) async {
    final File file = vault.file(relative);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  /// 去掉首尾空白并按字符数截断（不按字节，中文不会截半个字）。
  static String _clamp(String raw, int max) {
    final String trimmed = raw.trim();
    if (trimmed.length <= max) {
      return trimmed;
    }
    return trimmed.substring(0, max);
  }
}
