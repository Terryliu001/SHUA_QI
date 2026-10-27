import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/app/device/device_info.dart';
import 'package:shuaqi/app/feedback/feedback_config.dart';
import 'package:shuaqi/app/feedback/feedback_entry.dart';
import 'package:shuaqi/app/feedback/feedback_outbox.dart';
import 'package:shuaqi/domain/feedback/feedback.dart';
import 'package:shuaqi/state/settings_providers.dart';
import 'package:shuaqi/ui/settings/settings_subpage.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 关于 → 用户反馈。
///
/// ## 2026-10-27：通道真正接通
/// 上一版只做了表单，发送落到本机草稿（并且明说"没上传"）。这一版：
/// 1. **先落盘再发送**（`FeedbackOutbox`）：任何失败都不会丢用户写的东西；
/// 2. 配了 `FEEDBACK_GH_TOKEN`（私有反馈仓库）或 `FEEDBACK_ENDPOINT` 时
///    真的发出去，拿到 issue 号才算"已送达"；
/// 3. 发不出去时进"待发送/发送失败"，可手动重试，也会在下次启动/回前台时
///    自动补发；列表里能看到每一条的状态与失败原因。
///
/// **不做假成功**：`已送达` 只在远端明确回执（issue 号/成功响应）后出现。
class FeedbackPage extends ConsumerStatefulWidget {
  const FeedbackPage({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends ConsumerState<FeedbackPage> {
  FeedbackKind _kind = FeedbackKind.bug;
  final TextEditingController _text = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final List<Uint8List> _images = <Uint8List>[];

  bool _submitting = false;
  bool _busyList = false;
  bool _retryingAll = false;
  FeedbackReceipt? _receipt;
  String? _error;
  String _device = '';
  List<FeedbackEntry> _entries = <FeedbackEntry>[];

  @override
  void initState() {
    super.initState();
    unawaited(_loadDevice());
    unawaited(_reloadEntries());
    // 打开页面顺手补发一次：上次没网的反馈不用用户再点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_autoRetry());
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _loadDevice() async {
    final String device = await DeviceInfo.describe();
    if (mounted) {
      setState(() => _device = device);
    }
  }

  Future<void> _autoRetry() async {
    final FeedbackOutbox outbox = ref.read(feedbackOutboxProvider);
    if (!outbox.canSend) {
      return;
    }
    final List<FeedbackEntry> entries = await outbox.list();
    if (!mounted || !entries.any((FeedbackEntry e) => e.canRetry)) {
      return;
    }
    final int sent = await outbox.retryPending();
    if (!mounted) {
      return;
    }
    await _reloadEntries();
    if (sent > 0 && mounted) {
      _toast('补发了 $sent 条之前没发出去的反馈');
    }
  }

  Future<void> _reloadEntries() async {
    final FeedbackOutbox outbox = ref.read(feedbackOutboxProvider);
    try {
      final List<FeedbackEntry> entries = await outbox.list();
      if (mounted) {
        setState(() => _entries = entries);
      }
    } on Object {
      // 列表读不出来不影响提交。
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final FeedbackRemoteConfig config = ref.watch(feedbackRemoteConfigProvider);
    final FeedbackReceipt? receipt = _receipt;
    final int pending = _entries.where((FeedbackEntry e) => e.canRetry).length;
    return SettingsSubPageScaffold(
      page: SettingsSubPage.feedback,
      subtitle: '问题、建议、答案不对，都可以说',
      onClose: widget.onClose,
      child: SettingsSubPageBody(
        children: <Widget>[
          _Notice(
            config.enabled
                ? '提交后会发送给开发者（${config.channelLabel}）。'
                      '截图会上传到同一个私有位置，手机号只出现在私有记录里；'
                      '网络失败会先存本机，可手动或自动重试。'
                : '反馈通道还没配置，提交后只会存在本机，不会上传。'
                      '配置后面板会在联网时自动补发。',
            ok: config.enabled,
          ),
          const SubPageSectionTitle(text: '这是什么问题'),
          for (final FeedbackKind kind in FeedbackKind.values)
            _KindTile(
              kind: kind,
              selected: kind == _kind,
              onTap: () => setState(() => _kind = kind),
            ),
          const SubPageSectionTitle(text: '详细说明'),
          TextField(
            controller: _text,
            minLines: 4,
            maxLines: 8,
            maxLength: kMaxFeedbackTextLength,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              hintText: '例如：第 3 页的题目框拖不动，保存后刷新又回去了',
              isDense: true,
            ),
          ),
          const SubPageSectionTitle(text: '截图（最多 3 张）'),
          _ImageRow(
            images: _images,
            onAdd: _pickImage,
            onRemove: (int index) => setState(() => _images.removeAt(index)),
          ),
          const SubPageSectionTitle(text: '联系方式（选填）'),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            maxLength: 11,
            decoration: const InputDecoration(
              hintText: '11 位手机号，修复后短信回复',
              isDense: true,
            ),
          ),
          const SizedBox(height: ShqSpace.md),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: ShqSpace.sm),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.error,
                  height: 1.5,
                ),
              ),
            ),
          if (receipt != null)
            Padding(
              padding: const EdgeInsets.only(bottom: ShqSpace.sm),
              child: _ReceiptCard(receipt: receipt),
            ),
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined, size: 18),
            label: Text(_submitting ? '正在提交…' : (config.enabled ? '提交' : '存到本机')),
          ),
          const SizedBox(height: ShqSpace.sm),
          Text(
            '版本 ${AppInfo.version}'
            '${_device.isEmpty ? '' : ' · $_device'} · 反馈里会带上这行信息，方便定位',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: ShqSpace.lg),
          if (_entries.isNotEmpty) ...<Widget>[
            const SubPageSectionTitle(text: '我提过的反馈'),
            if (pending > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: ShqSpace.sm),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '$pending 条还没发出去。联网后会自动重试，也可以手动点。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ),
                    if (config.enabled)
                      TextButton(
                        onPressed: _retryingAll ? null : _retryAll,
                        child: Text(_retryingAll ? '正在重试…' : '全部重试'),
                      ),
                  ],
                ),
              ),
            for (final FeedbackEntry entry in _entries)
              _EntryCard(
                entry: entry,
                onRetry: entry.canRetry && config.enabled
                    ? () => unawaited(_retry(entry))
                    : null,
                onDelete: _busyList ? null : () => unawaited(_delete(entry)),
                onCopy: () => _copyEntry(entry),
              ),
            const SizedBox(height: ShqSpace.lg),
          ],
        ],
      ),
    );
  }

  Future<void> _pickImage() async {
    if (_images.length >= kMaxFeedbackImages) {
      setState(() => _error = '最多 $kMaxFeedbackImages 张图');
      return;
    }
    List<PlatformFile> picked = const <PlatformFile>[];
    try {
      picked = await FilePicker.pickFiles(type: FileType.image);
    } on Object {
      setState(() => _error = '打不开系统相册');
      return;
    }
    if (picked.isEmpty || !mounted) {
      return;
    }
    final String? path = picked.first.path;
    if (path == null || path.isEmpty) {
      setState(() => _error = '这张图读不出来，换一张试试');
      return;
    }
    final Uint8List? bytes = await _readCapped(path);
    if (!mounted) {
      return;
    }
    if (bytes == null) {
      setState(() => _error = '这张图太大了（超过 6MB），换一张小一点的');
      return;
    }
    setState(() {
      _error = null;
      _images.add(bytes);
    });
  }

  Future<Uint8List?> _readCapped(String path) async {
    final File file = File(path);
    if (!file.existsSync()) {
      return null;
    }
    if (file.lengthSync() > kMaxFeedbackImageBytes) {
      return null;
    }
    try {
      return await file.readAsBytes();
    } on Object {
      return null;
    }
  }

  Future<void> _submit() async {
    final String? textError = validateFeedbackText(_text.text);
    final String? phoneError = validateFeedbackPhone(_phone.text);
    final String? imageError = validateFeedbackImages(_images);
    final String? first = textError ?? phoneError ?? imageError;
    if (first != null) {
      setState(() => _error = first);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _receipt = null;
    });
    try {
      final ({FeedbackEntry entry, FeedbackReceipt receipt}) result = await ref
          .read(feedbackOutboxProvider)
          .submit(
            FeedbackDraft(
              kind: _kind,
              text: _text.text,
              phone: _phone.text,
              images: List<Uint8List>.of(_images),
              appVersion: AppInfo.version,
              device: _device,
            ),
            appVersion: AppInfo.version,
            device: _device,
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _receipt = result.receipt;
        if (result.entry.delivered) {
          _text.clear();
          _phone.clear();
          _images.clear();
        }
      });
      await _reloadEntries();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = '提交失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _retry(FeedbackEntry entry) async {
    setState(() => _busyList = true);
    try {
      final FeedbackEntry next = await ref
          .read(feedbackOutboxProvider)
          .send(entry);
      if (!mounted) {
        return;
      }
      _toast(next.delivered ? '已送达 #${next.issueNumber ?? ''}' : '还是没发出去：${next.lastError ?? ''}');
      await _reloadEntries();
    } finally {
      if (mounted) {
        setState(() => _busyList = false);
      }
    }
  }

  Future<void> _retryAll() async {
    setState(() => _retryingAll = true);
    try {
      final int sent = await ref.read(feedbackOutboxProvider).retryPending();
      if (!mounted) {
        return;
      }
      _toast(sent == 0 ? '这次没发出去，稍后再试' : '补发了 $sent 条');
      await _reloadEntries();
    } finally {
      if (mounted) {
        setState(() => _retryingAll = false);
      }
    }
  }

  Future<void> _delete(FeedbackEntry entry) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删掉这条反馈？'),
        content: Text(
          entry.delivered
              ? '远端已经收到了，删掉只会清掉本机这条记录。'
              : '这条还没发出去，删掉后内容就没有了。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    setState(() => _busyList = true);
    try {
      await ref.read(feedbackOutboxProvider).delete(entry);
      await _reloadEntries();
    } finally {
      if (mounted) {
        setState(() => _busyList = false);
      }
    }
  }

  void _copyEntry(FeedbackEntry entry) {
    final StringBuffer text = StringBuffer()
      ..writeln('【${entry.kind.label}】${entry.text}')
      ..writeln()
      ..writeln('版本 ${entry.appVersion} · ${entry.device}')
      ..writeln('时间 ${_formatTime(entry.createdAt)}');
    if (entry.issueNumber != null) {
      text.writeln('远端 #${entry.issueNumber} ${entry.issueUrl ?? ''}');
    }
    unawaited(Clipboard.setData(ClipboardData(text: text.toString())));
    _toast('已复制这条反馈');
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1800),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

String _formatTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

class _ReceiptCard extends StatelessWidget {
  const _ReceiptCard({required this.receipt});

  final FeedbackReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool ok = receipt.delivered;
    return Container(
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: ok
            ? scheme.secondaryContainer.withValues(alpha: 0.5)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(
          color: ok ? scheme.primary.withValues(alpha: 0.5) : scheme.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            ok ? Icons.check_circle_outline : Icons.cloud_off_outlined,
            size: 18,
            color: ok ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Text(
              receipt.message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.entry,
    required this.onRetry,
    required this.onDelete,
    required this.onCopy,
  });

  final FeedbackEntry entry;
  final VoidCallback? onRetry;
  final VoidCallback? onDelete;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final (String statusText, Color statusColor) = switch (entry.status) {
      FeedbackStatus.sent => ('已送达', scheme.primary),
      FeedbackStatus.failed => ('发送失败', scheme.error),
      FeedbackStatus.pending => ('待发送', scheme.onSurfaceVariant),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: ShqSpace.sm),
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: ShqSpace.xs,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(ShqRadius.pill),
                  border: Border.all(color: statusColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  statusText,
                  style: theme.textTheme.labelSmall?.copyWith(color: statusColor),
                ),
              ),
              const SizedBox(width: ShqSpace.sm),
              Text(
                entry.kind.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Text(
                _formatTime(entry.createdAt),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ),
          const SizedBox(height: ShqSpace.xs),
          Text(
            entry.summary,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurface,
              height: 1.5,
            ),
          ),
          if (entry.delivered && entry.issueNumber != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              '远端 issue #${entry.issueNumber}${entry.attempts > 1 ? ' · 第 ${entry.attempts} 次尝试' : ''}',
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary),
            ),
          ],
          if (!entry.delivered && entry.lastError != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              entry.lastError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: ShqSpace.xs),
          Row(
            children: <Widget>[
              TextButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.copy_all_outlined, size: 15),
                label: const Text('复制'),
              ),
              if (onRetry != null)
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 15),
                  label: const Text('重试'),
                ),
              const Spacer(),
              IconButton(
                tooltip: '删除这条',
                onPressed: onDelete,
                icon: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KindTile extends StatelessWidget {
  const _KindTile({
    required this.kind,
    required this.selected,
    required this.onTap,
  });

  final FeedbackKind kind;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: ShqSpace.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        child: Container(
          padding: const EdgeInsets.all(ShqSpace.md),
          decoration: BoxDecoration(
            color: selected
                ? scheme.secondaryContainer.withValues(alpha: 0.55)
                : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(ShqRadius.md),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected ? scheme.primary : scheme.outline,
              ),
              const SizedBox(width: ShqSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      kind.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      kind.hint,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImageRow extends StatelessWidget {
  const _ImageRow({
    required this.images,
    required this.onAdd,
    required this.onRemove,
  });

  final List<Uint8List> images;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Wrap(
      spacing: ShqSpace.sm,
      runSpacing: ShqSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        for (int i = 0; i < images.length; i += 1)
          Stack(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(ShqRadius.sm),
                child: Image.memory(
                  images[i],
                  width: 72,
                  height: 72,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: InkWell(
                  onTap: () => onRemove(i),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: scheme.scrim.withValues(alpha: 0.72),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 14,
                      color: ShqScrim.foreground,
                    ),
                  ),
                ),
              ),
            ],
          ),
        if (images.length < kMaxFeedbackImages)
          InkWell(
            onTap: onAdd,
            borderRadius: BorderRadius.circular(ShqRadius.sm),
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(ShqRadius.sm),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '添加',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text, {required this.ok});

  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(
          color: ok ? scheme.primary.withValues(alpha: 0.4) : scheme.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            ok ? Icons.mark_email_read_outlined : Icons.info_outline,
            size: 18,
            color: ok ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.65,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
