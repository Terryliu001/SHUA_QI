import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/app/backup_file.dart';
import 'package:shuaqi/domain/app/backup_naming.dart';

void main() {
  test('默认命名：手动导出带时间，更新前备份带目标版本', () {
    final DateTime at = DateTime(2026, 10, 28, 13, 45);
    expect(defaultBackupBaseName(at), 'SHUAQI_backup_20261028-1345');
    expect(
      beforeUpdateBackupBaseName(targetVersion: '0.1.3', now: at),
      'SHUAQI_backup_before_v0.1.3_20261028-1345',
    );
    expect(
      isBeforeUpdateBackupName('SHUAQI_backup_before_v0.1.3_20261028-1345.zip'),
      isTrue,
    );
    expect(
      isBeforeUpdateBackupName('SHUAQI_backup_20261028-1345.zip'),
      isFalse,
    );
  });

  test('用户命名：去非法字符、强制 .zip、空名判无效', () {
    expect(sanitizeBackupBaseName('  我的 备份/v2  '), '我的 备份_v2');
    expect(ensureZipName('abc'), 'abc.zip');
    expect(ensureZipName('abc.ZIP'), 'abc.ZIP');
    expect(isValidBackupBaseName('我的备份'), isTrue);
    expect(isValidBackupBaseName('   '), isFalse);
    expect(isValidBackupBaseName('...'), isFalse);
    expect(backupBaseNameOf('a.zip'), 'a');
  });

  test('重名自动加 -2、-3', () {
    expect(
      dedupeBackupName('SHUAQI_backup_1', <String>{}),
      'SHUAQI_backup_1.zip',
    );
    expect(
      dedupeBackupName('SHUAQI_backup_1', <String>{'SHUAQI_backup_1.zip'}),
      'SHUAQI_backup_1-2.zip',
    );
    expect(
      dedupeBackupName('SHUAQI_backup_1', <String>{
        'SHUAQI_backup_1.zip',
        'SHUAQI_backup_1-2.zip',
      }),
      'SHUAQI_backup_1-3.zip',
    );
  });

  test('BackupFileInfo：JSON 往返 / 更新前标记 / 时间', () {
    final BackupFileInfo info = BackupFileInfo.fromJson(<String, Object?>{
      'uri': 'content://media/external/downloads/1',
      'name': 'SHUAQI_backup_before_v0.1.3_20261028-1345.zip',
      'size': 1234,
      'modified': 1700000000000,
      'owned': true,
    });
    expect(info.id, 'content://media/external/downloads/1');
    expect(info.isBeforeUpdate, isTrue);
    expect(info.sizeBytes, 1234);
    expect(info.copyWith(name: 'x.zip').name, 'x.zip');
  });
}
