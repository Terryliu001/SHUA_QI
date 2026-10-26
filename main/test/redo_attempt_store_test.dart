import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/app/favorite/redo_attempt_store.dart';
import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/domain/model/redo_attempt.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

void main() {
  late Directory temp;
  late Vault vault;
  late RedoAttemptStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('shuaqi-redo-test-');
    vault = await Vault.open(temp.path);
    store = RedoAttemptStore(vault);
  });

  tearDown(() async {
    if (temp.existsSync()) {
      await temp.delete(recursive: true);
    }
  });

  test('创建 / 列出 / 读取 / 删除一次重刷', () async {
    final RedoAttempt attempt = await store.create(
      favoriteId: 'fav1',
      attemptId: 'run1',
      now: DateTime(2026, 10, 26, 20, 0),
      setId: 'set1',
      setTitle: '期中冲刺',
      paper: AnswerPaper.defaults.copyWith(pages: 2),
    );
    expect(attempt.saved, false);
    expect(attempt.paperPages, 2);

    final List<RedoAttempt> listed = await store.list('fav1');
    expect(listed.length, 1);
    expect(listed.first.id, 'run1');
    expect(listed.first.setTitle, '期中冲刺');

    await store.saveMeta(listed.first.copyWith(saved: true));
    final RedoAttempt? loaded = await store.load('fav1', 'run1');
    expect(loaded?.saved, true);

    await store.delete('fav1', 'run1');
    expect(await store.list('fav1'), isEmpty);
  });

  test('旧版单份重刷迁移成 legacy attempt，不丢笔迹', () async {
    await vault.writeAtomically(
      VaultPaths.favoriteInkSif('fav2', 0),
      Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    await vault.writeAtomically(
      VaultPaths.favoriteRedoPaper('fav2'),
      Uint8List.fromList(
        '{"size":"a4","orientation":"landscape","pages":2,"rule":"lines"}'
            .codeUnits,
      ),
    );

    final List<RedoAttempt> listed = await store.list('fav2');
    expect(listed.length, 1);
    expect(listed.first.id, startsWith('legacy-'));
    expect(listed.first.saved, true);
    expect(listed.first.paperPages, 2);
    final File copied = vault.file(
      VaultPaths.favoriteRedoInkSif('fav2', listed.first.id, 0),
    );
    expect(copied.existsSync(), true);
    expect(copied.readAsBytesSync(), <int>[1, 2, 3, 4]);
  });
}
