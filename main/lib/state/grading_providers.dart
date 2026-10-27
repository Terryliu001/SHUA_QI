import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/grade/grading_controller.dart';
import 'package:shuaqi/app/records/record_service.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/records/answer_log.dart';
import 'package:shuaqi/state/record_providers.dart';
import 'package:shuaqi/state/region_providers.dart';

/// 每卷一个判题控制器。数据源是 Vault 的 `grading.v1.json`。
///
/// 阶段 9 起顺带把"判题"写进作答记录：判出一个结论（对/错/待判）就算做过这道题，
/// 与用户口径一致（"保存、有笔迹更新、判题都算"）。写记录是旁路，
/// `RecordService` 内部吞异常，不会影响改卷本身。
final Provider<GradingController> Function(String) gradingProvider =
    Provider.family<GradingController, String>((Ref ref, String workbookId) {
      final RecordService records = ref.watch(recordServiceProvider);
      final GradingController controller = GradingController(
        workbookId: workbookId,
        store: ref.watch(layoutStoreProvider),
        onGraded: (String questionId, AnswerVerdict verdict) {
          // 先补当天那条（没做过也说明"判过"），再把历史行的结论一起刷成最新。
          // 写完顺手让记录页失效：判题会改正确率，不能等用户切 tab。
          unawaited(
            records
                .touch(
                  workbookId: workbookId,
                  questionId: questionId,
                  source: RecordSource.grade,
                  verdict: verdict,
                )
                .then(
                  (_) => records.syncVerdict(
                    workbookId: workbookId,
                    questionId: questionId,
                    verdict: verdict,
                  ),
                )
                .whenComplete(() {
                  ref.invalidate(recordsOverviewProvider);
                  ref.invalidate(recordsTimelineProvider);
                }),
          );
        },
      );
      ref.onDispose(controller.dispose);
      unawaited(controller.load());
      return controller;
    });
