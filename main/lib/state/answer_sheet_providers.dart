import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/answer/answer_sheet_controller.dart';
import 'package:shuaqi/state/region_providers.dart';

/// 每卷一个作答框控制器。数据源仍是 Vault 的 `answer_sheet.v1.json`。
final Provider<AnswerSheetController> Function(String) answerSheetProvider =
    Provider.family<AnswerSheetController, String>((Ref ref, String workbookId) {
      final AnswerSheetController controller = AnswerSheetController(
        workbookId: workbookId,
        store: ref.watch(layoutStoreProvider),
      );
      ref.onDispose(controller.dispose);
      unawaited(controller.load());
      return controller;
    });
