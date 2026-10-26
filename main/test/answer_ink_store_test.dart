import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/answer_sheet.dart';
import 'package:shuaqi/infra/ink/answer_ink_store.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';
import 'package:shuaqi/state/ink_providers.dart';

void main() {
  InkDoc docWith(int count) {
    return InkDoc(
      revision: count,
      strokes: <InkStroke>[
        for (int i = 0; i < count; i++)
          InkStroke(
            uid: 's$i',
            points: <InkPoint>[
              InkPoint(x: 100 + i * 20, y: 100, t: i * 10),
              InkPoint(x: 140 + i * 20, y: 180, t: i * 10 + 5),
            ],
          ),
      ],
    );
  }

  test('答题卡 session 编码可逆，普通 session 不会被误认', () {
    final String key = answerInkSessionId('01SESSION', '01QUESTION');
    expect(key, 'ans:01SESSION:01QUESTION');
    final ({String sessionId, String questionId})? parsed =
        parseAnswerInkSession(key);
    expect(parsed?.sessionId, '01SESSION');
    expect(parsed?.questionId, '01QUESTION');
    expect(parseAnswerInkSession('01SESSION#0'), isNull);
    expect(parseAnswerInkSession('ans:onlytwo'), isNull);
  });

  test('答题卡画布是固定 1000×600，独立于 PDF 页面尺寸', () {
    expect(AnswerCanvas.widthPt, 1000);
    expect(AnswerCanvas.heightPt, 600);
    expect(AnswerCanvas.aspect, closeTo(5 / 3, 0.0001));
  });

  test('AnswerInkStore 存取与 .bak 恢复', () async {
    final Directory dir = await Directory.systemTemp.createTemp('shq_ans_ink_');
    addTearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });
    final Vault vault = await Vault.open(dir.path);
    final AnswerInkStore store = AnswerInkStore(
      vault: vault,
      workbookId: 'w1',
      sessionId: 's1',
      questionId: 'q1',
    );

    expect((await store.load('s1', 0)).isEmpty, isTrue);

    await store.save('s1', 0, docWith(1));
    final InkDoc first = await store.load('s1', 0);
    expect(first.strokeCount, 1);
    expect(first.strokes.first.points.length, 2);

    await store.save('s1', 0, docWith(3));
    final InkDoc second = await store.load('s1', 0);
    expect(second.strokeCount, 3);

    // 主文件损坏：应从 .bak（上一版 1 笔）恢复，而不是丢掉整题。
    final File primary = vault.file(
      VaultPaths.answerInk('w1', 's1', 'q1'),
    );
    await primary.writeAsBytes(Uint8List.fromList(<int>[1, 2, 3]), flush: true);
    final InkDoc recovered = await store.load('s1', 0);
    expect(recovered.strokeCount, 1);
    // SIF 不持久化 uid（解码时重新生成），这里只校验几何还在。
    expect(recovered.strokes.first.points.length, 2);
    expect(recovered.strokes.first.points.first.x, closeTo(100, 1));
  });

  test('不同题目的答题卡 SIF 互不覆盖', () async {
    final Directory dir = await Directory.systemTemp.createTemp('shq_ans_ink_');
    addTearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });
    final Vault vault = await Vault.open(dir.path);
    final AnswerInkStore a = AnswerInkStore(
      vault: vault,
      workbookId: 'w1',
      sessionId: 's1',
      questionId: 'q1',
    );
    final AnswerInkStore b = AnswerInkStore(
      vault: vault,
      workbookId: 'w1',
      sessionId: 's1',
      questionId: 'q2',
    );
    await a.save('s1', 0, docWith(2));
    await b.save('s1', 0, docWith(4));
    expect((await a.load('s1', 0)).strokeCount, 2);
    expect((await b.load('s1', 0)).strokeCount, 4);
  });
}
