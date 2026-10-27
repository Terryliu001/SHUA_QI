import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shuaqi/app/feedback/feedback_entry.dart';
import 'package:shuaqi/domain/feedback/feedback.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 反馈草稿箱 + 发送队列（2026-10-27）。
///
/// 版式（与 2026-10-26 那版兼容）：
/// ```
/// vault/feedback/<id>.json      // FeedbackEntry（正文 + 状态 + 远端回执）
/// vault/feedback/<id>-<i>.img   // 原始截图字节
/// ```
///
/// 一条反馈的生命周期：
/// ```
/// 用户点提交 → enqueue（**先落盘**）→ send（尝试远端）
///   ├─ 成功：status=sent + issue 号，界面清空表单
///   └─ 失败：status=failed + 原因，界面说清"没发出去、可重试"
/// 下次启动 / 回到前台 / 打开反馈页 → retryPending() 自动补发
/// ```
///
/// 为什么先落盘再发：网络、凭证、进程被杀都可能中断。先落盘保证
/// **用户写的东西不会因为一次失败就消失**；[FeedbackStatus.sent] 则只由
/// 远端的明确回执产生，不猜、不假装。
class FeedbackOutbox {
  FeedbackOutbox({required this.vault, this.remote});

  final Vault vault;

  /// null = 没有配置任何远端通道（只存本机）。
  final FeedbackGateway? remote;

  /// 服务端回执失败时的兜底提示（本机已存）。
  static const String queuedHint = '这条已经存在本机草稿箱里，联网后可以点「重试」再发一次。';

  bool get canSend => remote != null;

  /// 串行发送：同一条不会并发发两次（避免重复 issue）。
  final Set<String> _sending = <String>{};

  Directory get _dir => vault.dir(VaultPaths.feedbackRoot);

  /// 全部反馈（新的在前）。读不动的文件跳过，不让一条坏草稿卡住整页。
  Future<List<FeedbackEntry>> list() async {
    final Directory dir = _dir;
    if (!dir.existsSync()) {
      return const <FeedbackEntry>[];
    }
    final List<FeedbackEntry> entries = <FeedbackEntry>[];
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      final String name = entity.uri.pathSegments.last;
      final String id = name.substring(0, name.length - '.json'.length);
      try {
        final Object? decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map) {
          continue;
        }
        final FeedbackEntry? entry = FeedbackEntry.fromJson(
          decoded.cast<String, Object?>(),
          id: id,
        );
        if (entry != null) {
          entries.add(entry);
        }
      } on Object {
        // 坏文件不删（可能是磁盘问题），只是这一条不显示。
      }
    }
    entries.sort((FeedbackEntry a, FeedbackEntry b) {
      return b.createdAt.compareTo(a.createdAt);
    });
    return entries;
  }

  Future<FeedbackEntry?> findByIssue(int number) async {
    for (final FeedbackEntry entry in await list()) {
      if (entry.issueNumber == number) {
        return entry;
      }
    }
    return null;
  }

  /// 落盘一条新反馈（**不发送**）。返回带 id 的条目。
  Future<FeedbackEntry> enqueue(FeedbackDraft draft, {String appVersion = '', String device = ''}) async {
    final String id = Ulid.next();
    final List<String> imagePaths = <String>[];
    for (int i = 0; i < draft.images.length; i += 1) {
      final String path = VaultPaths.feedbackImage(id, i);
      await vault.writeAtomically(path, draft.images[i]);
      imagePaths.add(path);
    }
    final FeedbackEntry entry = FeedbackEntry(
      id: id,
      kind: draft.kind,
      text: draft.text.trim(),
      phone: draft.phone.trim(),
      appVersion: appVersion.trim().isEmpty ? draft.appVersion : appVersion.trim(),
      device: device.trim().isEmpty ? draft.device : device.trim(),
      imagePaths: imagePaths,
      createdAt: DateTime.now(),
      status: FeedbackStatus.pending,
    );
    await _write(entry);
    return entry;
  }

  /// 提交一条新反馈：落盘 → 尝试远端 → 返回**更新后的**条目与回执。
  ///
  /// 返回的 `receipt` 是给界面看的结论；`entry` 是落盘后的真实状态。
  Future<({FeedbackEntry entry, FeedbackReceipt receipt})> submit(
    FeedbackDraft draft, {
    String appVersion = '',
    String device = '',
  }) async {
    final FeedbackEntry queued = await enqueue(
      draft,
      appVersion: appVersion,
      device: device,
    );
    final FeedbackEntry entry = await send(queued);
    final FeedbackReceipt receipt = entry.delivered
        ? FeedbackReceipt(
            delivered: true,
            message: entry.issueNumber == null
                ? '已提交给开发者，修复后会按你留的联系方式回复。'
                : '已提交给开发者（#${entry.issueNumber}），修复后会按你留的联系方式回复。',
            issueNumber: entry.issueNumber,
            issueUrl: entry.issueUrl,
            localPath: VaultPaths.feedbackDraft(entry.id),
          )
        : FeedbackReceipt(
            delivered: false,
            message: entry.lastError?.isNotEmpty == true
                ? '没发出去：${entry.lastError}；$queuedHint'
                : queuedHint,
            localPath: VaultPaths.feedbackDraft(entry.id),
          );
    return (entry: entry, receipt: receipt);
  }

  /// 发送一条已落盘的反馈。没有远端通道时原样返回（保持 pending）。
  Future<FeedbackEntry> send(FeedbackEntry entry) async {
    final FeedbackGateway? gateway = remote;
    if (gateway == null || entry.delivered || _sending.contains(entry.id)) {
      return entry;
    }
    _sending.add(entry.id);
    try {
      final List<Uint8List> images = <Uint8List>[];
      for (final String path in entry.imagePaths) {
        final File file = vault.file(path);
        if (file.existsSync()) {
          images.add(await file.readAsBytes());
        }
      }
      final FeedbackReceipt receipt;
      try {
        receipt = await gateway.submit(
          entry.toDraft(
            images: images,
            appVersion: entry.appVersion,
            device: entry.device,
          ),
        );
      } on Object catch (error) {
        final FeedbackEntry failed = entry.copyWith(
          status: FeedbackStatus.failed,
          attempts: entry.attempts + 1,
          lastError: '提交时出错：$error',
        );
        await _write(failed);
        return failed;
      }
      final FeedbackEntry next;
      if (receipt.delivered) {
        next = entry.copyWith(
          status: FeedbackStatus.sent,
          attempts: entry.attempts + 1,
          clearLastError: true,
          issueNumber: receipt.issueNumber,
          issueUrl: receipt.issueUrl,
          sentAt: DateTime.now(),
        );
      } else {
        next = entry.copyWith(
          status: FeedbackStatus.failed,
          attempts: entry.attempts + 1,
          lastError: receipt.message,
        );
      }
      await _write(next);
      return next;
    } finally {
      _sending.remove(entry.id);
    }
  }

  /// 自动补发：只发未送达的，按时间从旧到新；遇到第一条网络类失败就停，
  /// 避免离线时把整个队列挨个撞一遍（也省得触发限流）。
  ///
  /// 返回本次成功补发的条数。
  Future<int> retryPending({int limit = 8}) async {
    if (remote == null) {
      return 0;
    }
    final List<FeedbackEntry> pending = (await list())
        .where((FeedbackEntry e) => e.canRetry)
        .toList()
      ..sort((FeedbackEntry a, FeedbackEntry b) {
        return a.createdAt.compareTo(b.createdAt);
      });
    int sent = 0;
    for (final FeedbackEntry entry in pending.take(limit)) {
      final FeedbackEntry result = await send(entry);
      if (result.delivered) {
        sent += 1;
        continue;
      }
      // 网络没通：后面的多半也一样，先停。
      final String why = result.lastError ?? '';
      if (why.contains('网络') || why.contains('timeout') || why.contains('超时')) {
        break;
      }
    }
    return sent;
  }

  /// 删除一条反馈（连同本机截图）。
  Future<void> delete(FeedbackEntry entry) async {
    for (final String path in entry.imagePaths) {
      final File file = vault.file(path);
      if (file.existsSync()) {
        try {
          await file.delete();
        } on Object {
          // 删不掉也不影响记录删除。
        }
      }
    }
    final File json = vault.file(VaultPaths.feedbackDraft(entry.id));
    if (json.existsSync()) {
      await json.delete();
    }
  }

  /// 还没发出去的条数（设置页/记录页做小红点用）。
  Future<int> pendingCount() async {
    final List<FeedbackEntry> all = await list();
    return all.where((FeedbackEntry e) => e.canRetry).length;
  }

  Future<void> _write(FeedbackEntry entry) async {
    await vault.writeAtomically(
      VaultPaths.feedbackDraft(entry.id),
      Uint8List.fromList(utf8.encode(jsonEncode(entry.toJson()))),
    );
  }
}
