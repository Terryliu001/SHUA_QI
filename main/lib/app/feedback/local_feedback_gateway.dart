import 'package:shuaqi/app/feedback/feedback_entry.dart';
import 'package:shuaqi/app/feedback/feedback_outbox.dart';
import 'package:shuaqi/domain/feedback/feedback.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 本机落盘通道（2026-10-26 的首版实现，2026-10-27 起由
/// [FeedbackOutbox] 统一接管落盘 + 重试 + 状态，**新代码不要再直接用它**）。
///
/// 保留这个类只是为了：文档/旧引用不悬空，以及万一有测试要"只测落盘"。
/// 真正的提交入口是 `feedbackOutboxProvider`。
@Deprecated('本机落盘已并入 FeedbackOutbox；请改用 feedbackOutboxProvider')
class LocalFeedbackGateway implements FeedbackGateway {
  LocalFeedbackGateway({required this.vault});

  final Vault vault;

  @override
  Future<FeedbackReceipt> submit(FeedbackDraft draft) async {
    final FeedbackEntry entry = await FeedbackOutbox(vault: vault).enqueue(
      draft,
      appVersion: draft.appVersion,
      device: draft.device,
    );
    return FeedbackReceipt(
      delivered: false,
      message: '反馈通道还没接通，这条已经存在本机了（不会上传）',
      localPath: VaultPaths.feedbackDraft(entry.id),
    );
  }
}
