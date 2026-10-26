import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// AI 配置指导（2026-10-26 用户第 5 条：AI 配置里加 info 感叹号）。
///
/// 口径：
/// - 只写真实能用的配置路径，以 **DeepSeek** 为例；
/// - 把 `deepseek-flash`（支持图像理解）与 `deepseek-v4-pro`（不支持）
///   做成对比卡，用户一眼知道"判手写该选哪个"；
/// - 不假装能直接打开浏览器（白名单没有 url_launcher），提供复制按钮。
Future<void> showAiConfigGuide(
  BuildContext context, {
  void Function(String baseUrl, String model)? onApplyDeepSeek,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => _AiConfigGuideDialog(
      onApplyDeepSeek: onApplyDeepSeek,
    ),
  );
}

class _AiConfigGuideDialog extends StatelessWidget {
  const _AiConfigGuideDialog({this.onApplyDeepSeek});

  final void Function(String baseUrl, String model)? onApplyDeepSeek;

  /// DeepSeek 官方 OpenAI 兼容端点。应用会自动补 `/chat/completions`。
  static const String _endpoint = 'https://api.deepseek.com';
  static const String _model = 'deepseek-flash';

  void _copy(BuildContext context, String text, String what) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已复制$what'),
          duration: const Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return AlertDialog(
      title: Row(
        children: <Widget>[
          Icon(Icons.info_outline, size: 20, color: scheme.primary),
          const SizedBox(width: ShqSpace.sm),
          const Expanded(child: Text('API 配置指导')),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '本应用不内置 Key，也不做中转：你填一个 OpenAI 兼容端点，'
                '请求就从这台设备直接发过去。下面以 DeepSeek 为例。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.65,
                ),
              ),
              const SizedBox(height: ShqSpace.md),
              const _Step(
                index: 1,
                title: '注册并充值',
                body: '打开 platform.deepseek.com，注册/登录，按量充值。'
                    '费用由 DeepSeek 结算，本应用只显示 token 用量。',
              ),
              const _Step(
                index: 2,
                title: '创建 API Key',
                body: '在「API keys」里新建一个 Key（通常以 sk- 开头）。'
                    'Key 只显示一次，先复制保存；不要发到群里或截图公开。',
              ),
              const _Step(
                index: 3,
                title: '回到本页填三项',
                body: '端点、模型、Key 三项都填完才能保存。'
                    '端点填到域名即可，应用会自动补 /chat/completions。',
              ),
              const SizedBox(height: ShqSpace.sm),
              _EndpointCard(
                endpoint: _endpoint,
                onCopy: () => _copy(context, _endpoint, '端点'),
              ),
              const SizedBox(height: ShqSpace.md),
              Text(
                '选模型',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: ShqSpace.xs),
              Text(
                '本应用需要"看"题面与手写作答；是否支持图像理解是关键。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: ShqSpace.sm),
              const _ModelCards(),
              const SizedBox(height: ShqSpace.md),
              const _Warn(
                icon: Icons.visibility_outlined,
                title: '判手写请选 deepseek-flash',
                body: 'deepseek-flash 支持图像理解，能看题面与作答图；'
                    'deepseek-v4-pro 不支持图像，用它判手写会失败或只能依赖文字层。'
                    '选 pro 时请在表单里关掉「发送题面/作答图片」。',
              ),
              const SizedBox(height: ShqSpace.sm),
              const _Warn(
                icon: Icons.lock_outline,
                title: 'Key 只存在本机',
                body: 'Key 保存在应用私有目录的 setting 表里，不写日志、不随反馈上传。'
                    '换设备需要重新填。',
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => _copy(context, 'platform.deepseek.com', '平台地址'),
          child: const Text('复制平台地址'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
        if (onApplyDeepSeek != null)
          FilledButton(
            onPressed: () {
              onApplyDeepSeek!(_endpoint, _model);
              Navigator.of(context).pop();
            },
            child: const Text('填入示例'),
          ),
      ],
    );
  }
}

/// 端点卡：一行值 + 复制 + 说明。
class _EndpointCard extends StatelessWidget {
  const _EndpointCard({required this.endpoint, required this.onCopy});

  final String endpoint;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.md,
        ShqSpace.sm,
        ShqSpace.sm,
        ShqSpace.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                'BASE URL（OpenAI 格式）',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                  letterSpacing: 0.4,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '复制端点',
                onPressed: onCopy,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 16),
              ),
            ],
          ),
          SelectableText(
            endpoint,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '应用会自动补 /chat/completions；Anthropic 格式端点本应用不使用。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// 两个 DeepSeek 模型的对比卡。
///
/// 平板上一行放两张；窄屏自动竖排。视觉重点是「图像理解」这一行：
/// 判手写能不能用，就看它。
class _ModelCards extends StatelessWidget {
  const _ModelCards();

  @override
  Widget build(BuildContext context) {
    const List<Widget> cards = <Widget>[
      _ModelCard(
        name: 'deepseek-flash',
        version: 'DeepSeek-V4.1-Flash-1017',
        badge: '推荐 · 支持看图',
        vision: true,
        note: '判题、看题面、看手写都行；默认选它。',
      ),
      _ModelCard(
        name: 'deepseek-v4-pro',
        version: 'DeepSeek-V4-Pro-0813',
        badge: '纯文本',
        vision: false,
        note: '不支持图像；只适合有文字层的题，判手写会失败。',
      ),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= 500) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: cards[0]),
              const SizedBox(width: ShqSpace.sm),
              Expanded(child: cards[1]),
            ],
          );
        }
        return Column(
          children: <Widget>[
            cards[0],
            const SizedBox(height: ShqSpace.sm),
            cards[1],
          ],
        );
      },
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.name,
    required this.version,
    required this.badge,
    required this.vision,
    required this.note,
  });

  final String name;
  final String version;
  final String badge;
  final bool vision;
  final String note;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color accent = vision ? scheme.primary : scheme.outline;
    return Container(
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: vision
            ? scheme.primaryContainer.withValues(alpha: 0.28)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(
          color: vision ? scheme.primary.withValues(alpha: 0.55) : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                vision ? Icons.visibility_outlined : Icons.text_fields,
                size: 16,
                color: accent,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            version,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: ShqSpace.sm),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: <Widget>[
              const _InfoChip(label: '1M 上下文'),
              const _InfoChip(label: '384K 输出'),
              _InfoChip(
                label: vision ? '图像理解 ✓' : '图像理解 ✕',
                highlight: vision,
                warning: !vision,
              ),
              const _InfoChip(label: 'JSON / Tool'),
              const _InfoChip(label: '思考模式'),
            ],
          ),
          const SizedBox(height: ShqSpace.sm),
          Text(
            note,
            style: theme.textTheme.labelSmall?.copyWith(
              color: vision ? scheme.onSurfaceVariant : scheme.error,
              height: 1.55,
            ),
          ),
          const SizedBox(height: ShqSpace.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(ShqRadius.pill),
              ),
              child: Text(
                badge,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w600,
                  fontSize: 10,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.label,
    this.highlight = false,
    this.warning = false,
  });

  final String label;
  final bool highlight;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = warning
        ? scheme.error
        : highlight
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ShqRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: color, height: 1.3),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.index, required this.title, required this.body});

  final int index;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: ShqSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Warn extends StatelessWidget {
  const _Warn({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 17, color: scheme.tertiary),
          const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
