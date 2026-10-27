import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/app/feedback/feedback_entry.dart';
import 'package:shuaqi/app/feedback/feedback_outbox.dart';
import 'package:shuaqi/domain/feedback/feedback.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 反馈草稿箱（2026-10-27：反馈真正接通后的"先落盘、再发送、可重试"）。
///
/// 这些测试钉住四件用户会直接感受到的事：
/// 1. 提交失败**不丢内容**（json + 图片都在本机）；
/// 2. 只有远端明确回执才叫「已送达」，失败原因要看得到；
/// 3. 重试复用同一个 id，不会每次重试都换一份图片；
/// 4. 2026-10-26 那版老草稿（没有 status 字段）还能读、还能补发。
void main() {
  late Directory root;
  late Vault vault;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('shq_feedback_');
    vault = await Vault.open(root.path);
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Uint8List bytesOf(int seed) =>
      Uint8List.fromList(<int>[seed, seed + 1, seed + 2, seed + 3]);

  test('enqueue 先落盘：正文 JSON + 每张图都在，状态是 pending', () async {
    final FeedbackOutbox outbox = FeedbackOutbox(vault: vault);
    final FeedbackEntry entry = await outbox.enqueue(
      FeedbackDraft(
        kind: FeedbackKind.content,
        text: '第 3 页的答案不对',
        phone: '13800138000',
        images: <Uint8List>[bytesOf(1), bytesOf(9)],
        appVersion: '0.1.1',
        device: 'OPPO OPD2601 / Android 16',
      ),
      appVersion: '0.1.1',
      device: 'OPPO OPD2601 / Android 16',
    );

    expect(entry.status, FeedbackStatus.pending);
    expect(entry.attempts, 0);
    expect(vault.exists(VaultPaths.feedbackDraft(entry.id)), isTrue);
    expect(vault.exists(VaultPaths.feedbackImage(entry.id, 0)), isTrue);
    expect(vault.exists(VaultPaths.feedbackImage(entry.id, 1)), isTrue);
    expect(
      await vault.file(VaultPaths.feedbackImage(entry.id, 1)).readAsBytes(),
      bytesOf(9),
    );

    final List<FeedbackEntry> all = await FeedbackOutbox(vault: vault).list();
    expect(all, hasLength(1));
    expect(all.single.id, entry.id);
    expect(all.single.kind, FeedbackKind.content);
    expect(all.single.phone, '13800138000');
    expect(all.single.imagePaths, hasLength(2));
    expect(all.single.status, FeedbackStatus.pending);
  });

  test('远端成功：status=sent + issue 号；图片仍在（可回看）', () async {
    final _FakeGateway gateway = _FakeGateway();
    final FeedbackOutbox outbox = FeedbackOutbox(vault: vault, remote: gateway);
    final ({FeedbackEntry entry, FeedbackReceipt receipt}) result = await outbox
        .submit(
          FeedbackDraft(
            kind: FeedbackKind.bug,
            text: '题目框拖不动',
            images: <Uint8List>[bytesOf(3)],
          ),
          appVersion: '0.1.1',
          device: 'test-device',
        );

    expect(gateway.calls, 1);
    expect(result.entry.status, FeedbackStatus.sent);
    expect(result.entry.issueNumber, 7);
    expect(result.receipt.delivered, isTrue);
    expect(result.receipt.message, contains('#7'));
    // 重试用同一个 id（图片目录不会重复）。
    expect(gateway.lastDraft?.submissionId, result.entry.id);
    expect(
      await vault.file(VaultPaths.feedbackDraft(result.entry.id)).readAsString(),
      contains('"status":"sent"'),
    );
  });

  test('远端失败：不丢内容，记录原因；恢复后 retryPending 补发', () async {
    final _FakeGateway gateway = _FakeGateway(delivered: false);
    final FeedbackOutbox outbox = FeedbackOutbox(vault: vault, remote: gateway);
    final FeedbackEntry queued = await outbox.enqueue(
      FeedbackDraft(
        kind: FeedbackKind.bug,
        text: '平板上的笔迹偶尔断一下',
        images: <Uint8List>[bytesOf(5)],
      ),
      appVersion: '0.1.1',
      device: 'test-device',
    );

    final FeedbackEntry failed = await outbox.send(queued);
    expect(failed.status, FeedbackStatus.failed);
    expect(failed.lastError, contains('网络'));
    expect(failed.attempts, 1);
    expect(vault.exists(VaultPaths.feedbackImage(queued.id, 0)), isTrue);
    expect(await outbox.pendingCount(), 1);

    // 网络恢复。
    gateway.delivered = true;
    final int sent = await outbox.retryPending();
    expect(sent, 1);

    final FeedbackEntry done = (await outbox.list()).single;
    expect(done.status, FeedbackStatus.sent);
    expect(done.issueNumber, 7);
    expect(done.attempts, 2);
    expect(gateway.lastDraft?.submissionId, queued.id);
    expect(await outbox.pendingCount(), 0);
  });

  test('没有配置远端时只落本机：回执不假装成功，状态保持 pending', () async {
    final FeedbackOutbox outbox = FeedbackOutbox(vault: vault);
    final ({FeedbackEntry entry, FeedbackReceipt receipt}) result = await outbox
        .submit(const FeedbackDraft(kind: FeedbackKind.idea, text: '希望支持横屏锁定'));

    expect(result.receipt.delivered, isFalse);
    expect(result.receipt.message, contains('本机'));
    expect(result.entry.status, FeedbackStatus.pending);
    expect(await outbox.retryPending(), 0);
  });

  test('2026-10-26 的老草稿（没有 status/attempts）能读出来并补发', () async {
    const String id = '01OLD000000000000000000000';
    final Map<String, Object?> legacy = <String, Object?>{
      'id': id,
      'kind': 'bug',
      'text': '老格式的反馈正文',
      'phone': '',
      'app_version': '0.1.0',
      'device': 'OPPO OPD2601',
      'images': <String>[VaultPaths.feedbackImage(id, 0)],
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };
    await vault.writeAtomically(
      VaultPaths.feedbackDraft(id),
      Uint8List.fromList(utf8.encode(jsonEncode(legacy))),
    );
    await vault.writeAtomically(
      VaultPaths.feedbackImage(id, 0),
      bytesOf(7),
    );

    final _FakeGateway gateway = _FakeGateway();
    final FeedbackOutbox outbox = FeedbackOutbox(vault: vault, remote: gateway);
    final List<FeedbackEntry> all = await outbox.list();
    expect(all, hasLength(1));
    expect(all.single.id, id);
    expect(all.single.status, FeedbackStatus.pending);
    expect(all.single.attempts, 0);

    expect(await outbox.retryPending(), 1);
    expect(gateway.lastDraft?.submissionId, id);
    expect(gateway.lastDraft?.images.first, bytesOf(7));
  });

  test('delete 同时清掉 json 与附图', () async {
    final FeedbackOutbox outbox = FeedbackOutbox(vault: vault);
    final FeedbackEntry entry = await outbox.enqueue(
      FeedbackDraft(
        kind: FeedbackKind.bug,
        text: '这条要删掉',
        images: <Uint8List>[bytesOf(2)],
      ),
    );
    await outbox.delete(entry);
    expect(await outbox.list(), isEmpty);
    expect(vault.exists(VaultPaths.feedbackDraft(entry.id)), isFalse);
    expect(vault.exists(VaultPaths.feedbackImage(entry.id, 0)), isFalse);
  });

  test('坏 json 不会卡住整个列表', () async {
    await vault.writeAtomically(
      VaultPaths.feedbackDraft('01BROKEN000000000000000000'),
      Uint8List.fromList(utf8.encode('{not json')),
    );
    final FeedbackOutbox outbox = FeedbackOutbox(vault: vault);
    await outbox.enqueue(
      const FeedbackDraft(kind: FeedbackKind.bug, text: '正常的一条反馈'),
    );
    final List<FeedbackEntry> all = await outbox.list();
    expect(all, hasLength(1));
    expect(all.single.text, '正常的一条反馈');
  });
}

class _FakeGateway implements FeedbackGateway {
  _FakeGateway({this.delivered = true});

  bool delivered;
  int calls = 0;
  FeedbackDraft? lastDraft;

  @override
  Future<FeedbackReceipt> submit(FeedbackDraft draft) async {
    calls += 1;
    lastDraft = draft;
    if (!delivered) {
      return const FeedbackReceipt(delivered: false, message: '网络没接通');
    }
    return const FeedbackReceipt(
      delivered: true,
      message: '已提交给开发者（#7）',
      issueNumber: 7,
      issueUrl: 'https://github.com/Terryliu001/SHUA_QI_feedback/issues/7',
    );
  }
}
