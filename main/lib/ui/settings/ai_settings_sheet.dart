import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/state/ai_providers.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 打开 AI 配置弹层。返回 true = 保存过（调用方可以刷新配置）。
Future<bool> showAiSettingsSheet(
  BuildContext context, {
  required LlmConfig initial,
}) async {
  final bool? saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
    ),
    builder: (BuildContext context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: AiSettingsSheet(initial: initial),
    ),
  );
  return saved ?? false;
}

/// BYOK 配置表单（设置页与问 AI 面板共用一个入口）。
///
/// 设计口径：
/// - 只有"真实生效"的字段：保存后立刻用于下一次请求；
/// - Key 输入框永远留空，占位符提示"已保存 ••••1234（留空=不修改）"，
///   避免把明文 Key 再画到屏幕上；
/// - "测试连接"用当前表单值发一个 8 token 的请求，不先落库。
class AiSettingsSheet extends ConsumerStatefulWidget {
  const AiSettingsSheet({super.key, required this.initial});

  final LlmConfig initial;

  @override
  ConsumerState<AiSettingsSheet> createState() => _AiSettingsSheetState();
}

class _AiSettingsSheetState extends ConsumerState<AiSettingsSheet> {
  late final TextEditingController _baseUrl = TextEditingController(
    text: widget.initial.baseUrl,
  );
  late final TextEditingController _apiKey = TextEditingController();
  late final TextEditingController _model = TextEditingController(
    text: widget.initial.model,
  );
  late bool _allowImages = widget.initial.allowImages;
  late int _timeoutSeconds = widget.initial.timeout.inSeconds;
  bool _obscureKey = true;
  bool _testing = false;
  bool _saving = false;
  AiHealth? _health;
  String? _error;

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  LlmConfig get _draft {
    final String typedKey = _apiKey.text.trim();
    return LlmConfig(
      baseUrl: _baseUrl.text,
      apiKey: typedKey.isEmpty ? widget.initial.apiKey : typedKey,
      model: _model.text,
      allowImages: _allowImages,
      timeout: Duration(seconds: _timeoutSeconds),
    ).normalized();
  }

  Future<void> _test() async {
    if (_testing) {
      return;
    }
    setState(() {
      _testing = true;
      _health = null;
      _error = null;
    });
    final AiHealth health = await ref
        .read(aiDiagnosticsProvider)
        .testConnection(_draft);
    if (!mounted) {
      return;
    }
    setState(() {
      _health = health;
      _testing = false;
    });
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    final LlmConfig draft = _draft;
    final String? problem = draft.validationError();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    await ref.read(llmConfigStoreProvider).save(draft);
    ref.invalidate(aiConfigProvider);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _clear() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清除 AI 配置？'),
        content: const Text('会删掉端点、Key 与模型名。已生成的对话与答案不受影响。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await ref.read(llmConfigStoreProvider).clear();
    ref.invalidate(aiConfigProvider);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  void _applyPreset(String baseUrl, String model) {
    setState(() {
      _baseUrl.text = baseUrl;
      _model.text = model;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool hasSavedKey = widget.initial.hasApiKey;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.sm,
        ShqSpace.lg,
        ShqSpace.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.auto_awesome, size: 18, color: scheme.primary),
              const SizedBox(width: ShqSpace.sm),
              Expanded(
                child: Text('AI 配置', style: theme.textTheme.titleMedium),
              ),
              if (widget.initial.isConfigured)
                TextButton(
                  onPressed: _saving ? null : _clear,
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.error,
                    minimumSize: const Size(0, 32),
                  ),
                  child: const Text('清除'),
                ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          const SizedBox(height: ShqSpace.xs),
          Text(
            '接入任意 OpenAI 兼容端点。配置只存本机，请求直接发往你填的地址。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: ShqSpace.md),
          Wrap(
            spacing: ShqSpace.sm,
            runSpacing: ShqSpace.sm,
            children: <Widget>[
              _PresetChip(
                label: 'DeepSeek',
                onTap: () => _applyPreset(
                  'https://api.deepseek.com/v1',
                  'deepseek-flash',
                ),
              ),
              _PresetChip(
                label: 'OpenAI',
                onTap: () =>
                    _applyPreset('https://api.openai.com/v1', 'gpt-4o-mini'),
              ),
              _PresetChip(
                label: '通义千问',
                onTap: () => _applyPreset(
                  'https://dashscope.aliyuncs.com/compatible-mode/v1',
                  'qwen-vl-max',
                ),
              ),
              // 国内常见兼容端点：只是快捷填入，模型名以厂商当前文档为准，可手改。
              _PresetChip(
                label: 'Kimi',
                onTap: () => _applyPreset(
                  'https://api.moonshot.cn/v1',
                  'moonshot-v1-8k',
                ),
              ),
              _PresetChip(
                label: '混元',
                onTap: () => _applyPreset(
                  'https://api.hunyuan.cloud.tencent.com/v1',
                  'hunyuan-turbos-latest',
                ),
              ),
              _PresetChip(
                label: '智谱 GLM',
                onTap: () => _applyPreset(
                  'https://open.bigmodel.cn/api/paas/v4',
                  'glm-4-flash',
                ),
              ),
            ],
          ),
          const SizedBox(height: ShqSpace.md),
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '端点',
              hintText: 'https://api.deepseek.com/v1',
              helperText: '填到 /v1 即可；会自动补 /chat/completions。',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText:
                  _error == '请填写端点地址' || _error == '端点要以 http:// 或 https:// 开头'
                  ? _error
                  : null,
            ),
            onChanged: (_) {
              if (_error != null) {
                setState(() => _error = null);
              }
            },
          ),
          const SizedBox(height: ShqSpace.md),
          TextField(
            controller: _apiKey,
            obscureText: _obscureKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: hasSavedKey
                  ? '已保存 ${widget.initial.maskedKey}（留空 = 不修改）'
                  : '粘贴你的 Key',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: _obscureKey ? '显示' : '隐藏',
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
                icon: Icon(
                  _obscureKey
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 19,
                ),
              ),
            ),
          ),
          const SizedBox(height: ShqSpace.xs),
          Text(
            'Key 只存在本机 App 私有目录；不会写进日志、导出或备份。',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: ShqSpace.md),
          TextField(
            controller: _model,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '模型名',
              hintText: 'deepseek-flash / qwen-vl-max',
              helperText: 'DeepSeek 深度思考用 deepseek-flash / deepseek-v4-pro',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) {
              if (_error == '请填写模型名') {
                setState(() => _error = null);
              }
            },
          ),
          const SizedBox(height: ShqSpace.lg),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('发送题面/作答图片', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      '公式题建议开；纯文本模型可关掉。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _allowImages,
                onChanged: (bool value) => setState(() => _allowImages = value),
              ),
            ],
          ),
          const SizedBox(height: ShqSpace.md),
          Text('超时', style: theme.textTheme.titleSmall),
          const SizedBox(height: ShqSpace.sm),
          Wrap(
            spacing: ShqSpace.sm,
            children: <Widget>[
              for (final int seconds in <int>[30, 60, 120])
                ChoiceChip(
                  label: Text('$seconds 秒'),
                  selected: _timeoutSeconds == seconds,
                  onSelected: (bool selected) {
                    if (selected) {
                      setState(() => _timeoutSeconds = seconds);
                    }
                  },
                ),
            ],
          ),
          if (_health != null) ...<Widget>[
            const SizedBox(height: ShqSpace.md),
            _HealthBanner(health: _health!),
          ] else if (_error != null) ...<Widget>[
            const SizedBox(height: ShqSpace.md),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: ShqSpace.xl),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (_testing || _saving) ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check, size: 18),
                  label: Text(_testing ? '测试中' : '测试连接'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 46),
                  ),
                ),
              ),
              const SizedBox(width: ShqSpace.md),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check, size: 18),
                  label: Text(_saving ? '保存中' : '保存'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _HealthBanner extends StatelessWidget {
  const _HealthBanner({required this.health});

  final AiHealth health;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color color = health.ok ? scheme.primary : scheme.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: ShqSpace.md,
        vertical: ShqSpace.sm,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ShqRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            health.ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              health.message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
