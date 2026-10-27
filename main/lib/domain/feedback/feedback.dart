/// 用户反馈的领域模型与校验（纯 Dart）。
///
/// 为什么先定模型再定通道：这一版**只做界面、留接口**（用户 2026-10-26 的
/// 第 2 条要求），所以"提交"这一层必须是可替换的实现——
/// 现在落到本机草稿，将来换成 HTTP 只改 [FeedbackGateway] 的实现。
library;

import 'dart:typed_data';

/// 反馈类型（决定后台分派给谁看，也决定界面的提示语）。
enum FeedbackKind {
  bug('功能异常', '闪退、卡住、点不动、数据不对'),
  idea('改进建议', '希望多一个功能，或某个地方不好用'),
  content('内容或答案有误', 'AI 答案、判题结论、切题结果不对');

  const FeedbackKind(this.label, this.hint);

  final String label;
  final String hint;

  static FeedbackKind decode(String? raw) {
    for (final FeedbackKind kind in values) {
      if (kind.name == raw) {
        return kind;
      }
    }
    return FeedbackKind.bug;
  }
}

/// 一条待提交的反馈。图片只在这一层持有字节（UI 预览 + 直接落盘）。
class FeedbackDraft {
  const FeedbackDraft({
    required this.kind,
    required this.text,
    this.phone = '',
    this.images = const <Uint8List>[],
    this.appVersion = '',
    this.device = '',
    this.submissionId = '',
  });

  final FeedbackKind kind;
  final String text;

  /// 选填：11 位手机号，修好后短信/电话回复。
  final String phone;

  /// ≤ [kMaxFeedbackImages] 张，每张 ≤ [kMaxFeedbackImageBytes]。
  final List<Uint8List> images;

  /// 帮助定位问题的上下文（版本号、设备型号）。不带任何个人信息。
  final String appVersion;
  final String device;

  /// 落盘/重试用的稳定 id（ULID）。空 = 由通道自己生成。
  ///
  /// 为什么要它：反馈先写本机再尝试远端；重试时必须复用同一个 id，
  /// 这样已经上传过的截图落在同一个 `feedback/<id>/` 里，不会每次重试
  /// 都在仓库里留一堆孤儿图片。
  final String submissionId;

  bool get hasPhone => phone.trim().isNotEmpty;

  /// 不含图片字节的元数据（落盘时图片单独存文件）。
  Map<String, Object?> toJson({required List<String> imageFiles}) =>
      <String, Object?>{
        'kind': kind.name,
        'text': text.trim(),
        'phone': phone.trim(),
        'app_version': appVersion,
        'device': device,
        'images': imageFiles,
        // created_at 由调用方补充（domain 不读系统时钟，方便单测）。
      };
}

/// 最多几张图：3 张足够说清"哪里不对"，再多会让人挑花眼。
const int kMaxFeedbackImages = 3;

/// 单张图上限 6MB：手机截屏通常 1–3MB，超过说明是大照片，先压再传。
const int kMaxFeedbackImageBytes = 6 * 1024 * 1024;

/// 正文上限。
const int kMaxFeedbackTextLength = 1000;

/// 正文最短：少于 5 个字基本无法定位问题。
const int kMinFeedbackTextLength = 5;

/// 校验正文。返回 null = 通过。
String? validateFeedbackText(String raw) {
  final String text = raw.trim();
  if (text.length < kMinFeedbackTextLength) {
    return '再多写几个字吧（至少 $kMinFeedbackTextLength 个字），不然没法定位';
  }
  if (text.length > kMaxFeedbackTextLength) {
    return '太长了，先精简到 $kMaxFeedbackTextLength 字以内';
  }
  return null;
}

/// 校验手机号。**空串合法**（选填）；非空则必须是 11 位且以 1 开头。
String? validateFeedbackPhone(String raw) {
  final String phone = raw.trim();
  if (phone.isEmpty) {
    return null;
  }
  if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
    return '手机号要 11 位、以 1 开头；不填也行';
  }
  return null;
}

/// 校验图片数量/大小。返回 null = 通过。
String? validateFeedbackImages(List<Uint8List> images) {
  if (images.length > kMaxFeedbackImages) {
    return '最多 $kMaxFeedbackImages 张图';
  }
  for (final Uint8List image in images) {
    if (image.length > kMaxFeedbackImageBytes) {
      return '有一张图超过 6MB，换一张小一点的';
    }
    if (image.isEmpty) {
      return '有一张图是空的，重新选一下';
    }
  }
  return null;
}

/// 一条反馈在本机草稿箱里的状态（2026-10-27：反馈真正接上远端后新增）。
///
/// 口径：
/// - [pending]：已存本机，还没确认送达（首次提交后网络失败、或通道没配）；
/// - [sent]：远端明确回了 issue 号 / 成功响应，**只有这一种算"发出去了"**；
/// - [failed]：尝试过且失败，等下次联网/手动重试。
///
/// 不存在"假装成功"的中间态：`sent` 一定要有远端凭证（issue 号或成功响应）。
enum FeedbackStatus {
  pending('待发送'),
  sent('已送达'),
  failed('发送失败');

  const FeedbackStatus(this.label);

  final String label;

  static FeedbackStatus decode(String? raw) {
    for (final FeedbackStatus status in values) {
      if (status.name == raw) {
        return status;
      }
    }
    return FeedbackStatus.pending;
  }
}

/// 提交结果（**不假设一定送达**）。
class FeedbackReceipt {
  const FeedbackReceipt({
    required this.delivered,
    required this.message,
    this.localPath,
    this.issueNumber,
    this.issueUrl,
  });

  /// true = 已发到服务器；false = 只落在本机（通道未开通 / 网络失败）。
  final bool delivered;

  /// 给用户看的结论句。
  final String message;

  /// 落盘位置（delivered=false 时给用户一个"东西在这"的交代）。
  final String? localPath;

  /// 远端回执：GitHub 私有仓库里的 issue 号与链接（delivered=true 时可能有）。
  final int? issueNumber;
  final String? issueUrl;
}

/// 反馈通道。实现由 `app/feedback/` 提供。
abstract interface class FeedbackGateway {
  Future<FeedbackReceipt> submit(FeedbackDraft draft);
}

/// 编译期注入的反馈端点；空 = 通道未接通（只存本机）。
///
/// 构建时：
/// `flutter build apk --dart-define=FEEDBACK_ENDPOINT=https://xxx.workers.dev`
const String kFeedbackEndpoint = String.fromEnvironment('FEEDBACK_ENDPOINT');
