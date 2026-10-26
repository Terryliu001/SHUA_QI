import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/app/backup_manifest.dart';
import 'package:shuaqi/ui/widgets/labeled_action.dart';

/// 备份 manifest 的版本闸门 + 文字模式的宽度闸门。
///
/// 这两条都是"**不能出错**"的判断：
/// - 备份版本比本机新时必须拒收（否则会把新表结构写进老库）；
/// - 文字模式放不下时必须退回纯图标（否则顶栏出黄黑条）。
void main() {
  test('manifest 序列化往返不丢字段', () {
    const BackupManifest manifest = BackupManifest(
      appVersion: '0.1.0',
      dbVersion: 7,
      createdAt: 1790000000000,
      workbooks: 3,
      favorites: 12,
      records: 48,
    );
    final BackupManifest back = BackupManifest.fromJson(manifest.toJson());
    expect(back.appVersion, '0.1.0');
    expect(back.dbVersion, 7);
    expect(back.workbooks, 3);
    expect(back.favorites, 12);
    expect(back.records, 48);
  });

  test('备份比本机新 → 拒收；等于或更老 → 放行', () {
    const BackupManifest newer = BackupManifest(
      appVersion: '0.2.0',
      dbVersion: 9,
      createdAt: 0,
      workbooks: 0,
      favorites: 0,
      records: 0,
    );
    const BackupManifest older = BackupManifest(
      appVersion: '0.1.0',
      dbVersion: 6,
      createdAt: 0,
      workbooks: 0,
      favorites: 0,
      records: 0,
    );
    expect(newer.canRestoreOn(7), isFalse);
    expect(older.canRestoreOn(7), isTrue);
  });

  test('坏 manifest 也能解析出默认值（不抛异常）', () {
    final BackupManifest manifest = BackupManifest.fromJson(
      <String, Object?>{'db_version': 3},
    );
    expect(manifest.dbVersion, 3);
    expect(manifest.appVersion, '');
  });

  test('文字模式：宽度不够就放不下', () {
    // 8 个动作 × 84dp + 预留 240dp = 912dp 才放得下。
    expect(
      labelsFitWidth(width: 1200, actionCount: 8),
      isTrue,
      reason: '平板横屏应当放得下',
    );
    expect(labelsFitWidth(width: 848, actionCount: 8), isFalse);
    expect(labelsFitWidth(width: 360, actionCount: 5), isFalse);
    expect(labelsFitWidth(width: 1200, actionCount: 5), isTrue);
  });
}
