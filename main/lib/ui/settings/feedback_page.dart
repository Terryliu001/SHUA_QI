import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/domain/feedback/feedback.dart';
import 'package:shuaqi/state/settings_providers.dart';
import 'package:shuaqi/ui/settings/settings_subpage.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 关于 → 用户反馈（2026-10-26 用户第 2 条：先把界面做好，接口留好）。
///
/// ## 这一版的真实边界
/// 表单、校验、选图、预览、删除图片**全是真的**；唯独"发送"这一步——
/// 后端通道还没开通，所以 [FeedbackGateway] 的当前实现把内容存到本机
/// `vault/feedback/`，并明确告诉用户"没上传"。**不做假成功**。
///
/// ## 为什么要手机号
/// 用户原话："填写用户手机号（修复后短信回复）"。所以它**选填**：
/// 愿意留联系方式的人留，不愿意的人照样能提问题。
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
  FeedbackReceipt? _receipt;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final FeedbackReceipt? receipt = _receipt;
    return SettingsSubPageScaffold(
      page: SettingsSubPage.feedback,
      subtitle: '问题、建议、答案不对，都可以说',
      onClose: widget.onClose,
      child: SettingsSubPageBody(
        children: <Widget>[
          _Notice(
            kFeedbackEndpoint.trim().isEmpty
                ? '提交后我们会按你留的联系方式回复。'
                      '这一版的反馈通道还没接通，内容会先存在本机，不会自动上传。'
                : '提交后会发送给开发者，修复后按你留的手机号短信/电话回复。'
                      '网络失败时内容会先存在本机，不会假装发送成功。',
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
              child: Container(
                padding: const EdgeInsets.all(ShqSpace.md),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(ShqRadius.md),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Text(
                  receipt.message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface,
                    height: 1.6,
                  ),
                ),
              ),
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
            label: Text(_submitting ? '正在提交…' : '提交'),
          ),
          const SizedBox(height: ShqSpace.sm),
          Text(
            '版本 ${AppInfo.version} · 反馈里会带上这个版本号，方便定位',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.outline,
            ),
          ),
          const SizedBox(height: ShqSpace.lg),
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
    final file = File(path);
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
      final FeedbackReceipt receipt = await ref
          .read(feedbackGatewayProvider)
          .submit(
            FeedbackDraft(
              kind: _kind,
              text: _text.text,
              phone: _phone.text,
              images: List<Uint8List>.of(_images),
              appVersion: AppInfo.version,
            ),
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _receipt = receipt;
        if (receipt.delivered) {
          _text.clear();
          _phone.clear();
          _images.clear();
        }
      });
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
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
          height: 1.65,
        ),
      ),
    );
  }
}
