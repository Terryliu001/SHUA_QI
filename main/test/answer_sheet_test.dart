import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/app/answer/answer_sheet_controller.dart';
import 'package:shuaqi/domain/model/answer_sheet.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';
import 'package:shuaqi/infra/vault/vault.dart';

void main() {
  QuestionBundle bundle() => QuestionBundle(
    question: const Question(
      id: 'q1',
      workbookId: 'w1',
      ordinal: 1,
      level: 2,
      confidence: 0.9,
      label: '1.',
    ),
    slices: <QuestionSlice>[
      QuestionSlice(
        pageIndex: 0,
        rect: RegionRect.fromLTRB(40, 100, 520, 260),
        pageId: 'p1',
      ),
      QuestionSlice(
        pageIndex: 1,
        rect: RegionRect.fromLTRB(40, 80, 520, 240),
        pageId: 'p2',
      ),
    ],
  );

  test('默认作答框 = 最后一段的整题区域（跨页题落在后一页）', () {
    final AnswerSheetEntry entry = AnswerSheetEntry.defaultFor(bundle());
    expect(entry.pageIndex, 1);
    expect(entry.rect, RegionRect.fromLTRB(40, 80, 520, 240));
    expect(entry.regionSource, AnswerRegionSource.auto);
    expect(entry.hasText, isFalse);
  });

  test('JSON 往返保留框、来源与识别状态', () {
    final AnswerSheetEntry entry = AnswerSheetEntry(
      questionId: 'q1',
      pageIndex: 2,
      rect: RegionRect.fromLTRB(10, 20, 300, 400),
      regionSource: AnswerRegionSource.manual,
      ocrText: 'x=1',
      ocrConfidence: 0.8,
      ocrEngine: 'ink_mlkit',
      cropPath: 'workbooks/w1/layout/answer_crops/q1.png',
      updatedAt: 123,
    );
    final AnswerSheetData round = AnswerSheetData.fromJson(<String, Object?>{
      'version': 1,
      'answers': <Object?>[entry.toJson()],
    });
    final AnswerSheetEntry? back = round.storedFor('q1');
    expect(back, isNotNull);
    expect(back!.pageIndex, 2);
    expect(back.rect, entry.rect);
    expect(back.manuallyAdjusted, isTrue);
    expect(back.ocrText, 'x=1');
    expect(back.cropPath, entry.cropPath);
  });

  test('控制器落盘后可重新读回，且 reset 保留识别文本', () async {
    final Directory dir = await Directory.systemTemp.createTemp('shq_answer_');
    addTearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });
    final Vault vault = await Vault.open(dir.path);
    final LayoutStore store = LayoutStore(vault);
    final AnswerSheetController first = AnswerSheetController(
      workbookId: 'w1',
      store: store,
    );
    await first.load();
    final QuestionBundle q = bundle();
    await first.updateRect(
      q,
      pageIndex: 0,
      rect: RegionRect.fromLTRB(100, 200, 300, 350),
    );
    await first.updateOcr(
      q,
      text: '答案痕迹',
      confidence: 0.9,
      engine: 'manual',
      cropPath: 'workbooks/w1/layout/answer_crops/q1.png',
    );
    await first.flush();

    final AnswerSheetController second = AnswerSheetController(
      workbookId: 'w1',
      store: store,
    );
    await second.load();
    final AnswerSheetEntry loaded = second.entryFor(q);
    expect(loaded.manuallyAdjusted, isTrue);
    expect(loaded.rect, RegionRect.fromLTRB(100, 200, 300, 350));
    expect(loaded.ocrText, '答案痕迹');
    expect(loaded.cropPath, isNotNull);

    await second.reset(q);
    final AnswerSheetEntry reset = second.entryFor(q);
    expect(reset.manuallyAdjusted, isFalse);
    expect(reset.pageIndex, 1);
    expect(reset.rect, RegionRect.fromLTRB(40, 80, 520, 240));
    expect(reset.ocrText, '答案痕迹');
  });
}
