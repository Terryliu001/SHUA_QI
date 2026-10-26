import 'dart:convert';
import 'dart:typed_data';

import 'package:shuaqi/domain/feedback/feedback.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 反馈通道的**本机实现**（2026-10-26：先做界面、留接口）。
///
/// 为什么要有这一层而不是直接 `throw UnimplementedError`：
/// 1. UI 需要一条真实可走的路径来验证表单、图片、手机号校验；
/// 2. 用户写下的内容不能因为"通道没接通"就丢掉——落到 `vault/feedback/`，
///    接上后端后可以把草稿一次性补传；
/// 3. 返回 [FeedbackReceipt.delivered] = false，界面据此说"已存本机"，
///    **不假装发送成功**（项目一贯的"不做假功能"）。
class LocalFeedbackGateway implements FeedbackGateway {
  LocalFeedbackGateway({required this.vault});

  final Vault vault;

  @override
  Future<FeedbackReceipt> submit(FeedbackDraft draft) async {
    final String id = Ulid.next();
    final List<String> imageFiles = <String>[];
    for (int i = 0; i < draft.images.length; i += 1) {
      final String path = VaultPaths.feedbackImage(id, i);
      await vault.writeAtomically(path, draft.images[i]);
      imageFiles.add(path);
    }
    final Map<String, Object?> payload = <String, Object?>{
      ...draft.toJson(imageFiles: imageFiles),
      'id': id,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };
    await vault.writeAtomically(
      VaultPaths.feedbackDraft(id),
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
    return FeedbackReceipt(
      delivered: false,
      message: '反馈通道还没接通，这条已经存在本机了（不会上传）',
      localPath: VaultPaths.feedbackDraft(id),
    );
  }
}
