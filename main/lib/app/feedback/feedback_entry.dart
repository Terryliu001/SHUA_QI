import 'dart:typed_data';

import 'package:shuaqi/domain/feedback/feedback.dart';

/// 一条已经落盘的反馈（本机草稿箱里的一格）。
///
/// 为什么把"待发送的反馈"做成实体而不是一提交就扔：
/// 1. 用户写下的东西不能因为当时没网就丢 —— 先落盘，再谈发送；
/// 2. 失败后要能**重试**、要看得到**发没发出去**，不能只弹一句 toast；
/// 3. 重试必须复用同一个 [id]，否则每次重试都会在远端仓库里留一批孤儿图片。
///
/// 存储格式（`vault/feedback/<id>.json`）刻意兼容 2026-10-26 那版
/// 本机草稿通道写下的字段：那版只有 `id/kind/text/phone/
/// app_version/device/images/created_at`，缺的状态字段在这里按
/// "pending + 0 次尝试"补齐，老草稿升级后可继续重试。
class FeedbackEntry {
  const FeedbackEntry({
    required this.id,
    required this.kind,
    required this.text,
    required this.createdAt,
    this.phone = '',
    this.appVersion = '',
    this.device = '',
    this.imagePaths = const <String>[],
    this.status = FeedbackStatus.pending,
    this.attempts = 0,
    this.lastError,
    this.issueNumber,
    this.issueUrl,
    this.sentAt,
  });

  final String id;
  final FeedbackKind kind;
  final String text;
  final String phone;
  final String appVersion;
  final String device;

  /// 图片在 Vault 里的**相对路径**（`feedback/<id>-<i>.img`）。
  final List<String> imagePaths;

  final DateTime createdAt;
  final FeedbackStatus status;

  /// 已经尝试发送的次数（含成功那次）。
  final int attempts;

  /// 最近一次失败的原因（给人看的短句）。
  final String? lastError;

  final int? issueNumber;
  final String? issueUrl;
  final DateTime? sentAt;

  bool get delivered => status == FeedbackStatus.sent;
  bool get canRetry => status != FeedbackStatus.sent;

  /// 列表里显示的一句话摘要（不把整段正文塞进列表）。
  String get summary {
    final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= 46) {
      return flat;
    }
    return '${flat.substring(0, 46)}…';
  }

  FeedbackEntry copyWith({
    FeedbackStatus? status,
    int? attempts,
    String? lastError,
    bool clearLastError = false,
    int? issueNumber,
    String? issueUrl,
    DateTime? sentAt,
  }) {
    return FeedbackEntry(
      id: id,
      kind: kind,
      text: text,
      phone: phone,
      appVersion: appVersion,
      device: device,
      imagePaths: imagePaths,
      createdAt: createdAt,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      issueNumber: issueNumber ?? this.issueNumber,
      issueUrl: issueUrl ?? this.issueUrl,
      sentAt: sentAt ?? this.sentAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.name,
    'text': text,
    'phone': phone,
    'app_version': appVersion,
    'device': device,
    'images': imagePaths,
    'created_at': createdAt.millisecondsSinceEpoch,
    'status': status.name,
    'attempts': attempts,
    'last_error': lastError,
    'issue_number': issueNumber,
    'issue_url': issueUrl,
    'sent_at': sentAt?.millisecondsSinceEpoch,
  };

  /// 宽松解析：缺字段/类型不对都不抛，最差也把能读出来的部分读出来。
  static FeedbackEntry? fromJson(Map<String, Object?> map, {required String id}) {
    final Object? text = map['text'];
    if (text is! String || text.trim().isEmpty) {
      return null;
    }
    final Object? rawImages = map['images'];
    final List<String> images = <String>[
      if (rawImages is List)
        for (final Object? item in rawImages)
          if (item is String && item.isNotEmpty) item,
    ];
    final int createdAtMillis = switch (map['created_at']) {
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value) ?? 0,
      _ => 0,
    };
    final int attempts = switch (map['attempts']) {
      final int value => value,
      final num value => value.toInt(),
      _ => 0,
    };
    final int? issueNumber = switch (map['issue_number']) {
      final int value => value,
      final num value => value.toInt(),
      _ => null,
    };
    final int? sentAtMillis = switch (map['sent_at']) {
      final int value => value,
      final num value => value.toInt(),
      _ => null,
    };
    return FeedbackEntry(
      id: id,
      kind: FeedbackKind.decode(map['kind'] as String?),
      text: text,
      phone: (map['phone'] as String?)?.trim() ?? '',
      appVersion: (map['app_version'] as String?) ?? '',
      device: (map['device'] as String?) ?? '',
      imagePaths: images,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMillis),
      status: FeedbackStatus.decode(map['status'] as String?),
      attempts: attempts,
      lastError: map['last_error'] as String?,
      issueNumber: issueNumber,
      issueUrl: map['issue_url'] as String?,
      sentAt: sentAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(sentAtMillis),
    );
  }

  /// 把这条落盘反馈还原成一次提交（重试时用）。
  FeedbackDraft toDraft({
    required List<Uint8List> images,
    required String appVersion,
    required String device,
  }) {
    return FeedbackDraft(
      kind: kind,
      text: text,
      phone: phone,
      images: images,
      appVersion: appVersion.isEmpty ? this.appVersion : appVersion,
      device: device.isEmpty ? this.device : device,
      submissionId: id,
    );
  }
}
