import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/region/question_order_controller.dart';
import 'package:shuaqi/state/region_providers.dart';

/// 每卷一个手动题目顺序控制器。
final Provider<QuestionOrderController> Function(String) questionOrderProvider =
    Provider.family<QuestionOrderController, String>((Ref ref, String workbookId) {
      final QuestionOrderController controller = QuestionOrderController(
        workbookId: workbookId,
        store: ref.watch(layoutStoreProvider),
      );
      ref.onDispose(controller.dispose);
      unawaited(controller.load());
      return controller;
    });
