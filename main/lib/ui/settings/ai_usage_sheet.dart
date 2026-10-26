import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/ai/usage.dart';
import 'package:shuaqi/state/ai_providers.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 打开 AI 用量明细。返回时不带结果；调用方不需要等。
Future<void> showAiUsageSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
    ),
    builder: (BuildContext context) => const _AiUsageSheet(),
  );
}

/// token 用量：累计 + 最近调用。
///
/// 口径：
/// - 端点返回 usage 的记录是**真实值**；
/// - 没返回的按字符估算，UI 统一加 `≈`，不把估算伪装成真实；
/// - 记账是旁路，失败只影响统计，不影响对话。
class _AiUsageSheet extends ConsumerWidget {
  const _AiUsageSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AsyncValue<AiUsageSnapshot> async = ref.watch(aiUsageProvider);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ShqSpace.lg,
              ShqSpace.sm,
              ShqSpace.xs,
              ShqSpace.sm,
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.data_usage, size: 18, color: scheme.primary),
                const SizedBox(width: ShqSpace.sm),
                Expanded(
                  child: Text('AI 用量', style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: '清空用量记录',
                  onPressed: () => _clear(context, ref),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: () => ref.invalidate(aiUsageProvider),
                  icon: const Icon(Icons.refresh, size: 20),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object error, StackTrace stack) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(ShqSpace.xl),
                  child: Text(
                    '读不到用量记录：$error',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              data: (AiUsageSnapshot snapshot) =>
                  _UsageBody(snapshot: snapshot),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _clear(BuildContext context, WidgetRef ref) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('清空用量记录？'),
      content: const Text('只删除统计历史，不会删除对话、答案或判题结论。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('清空'),
        ),
      ],
    ),
  );
  if (confirmed != true) {
    return;
  }
  await ref.read(aiUsageServiceProvider).clear();
  ref.invalidate(aiUsageProvider);
}

class _UsageBody extends StatelessWidget {
  const _UsageBody({required this.snapshot});

  final AiUsageSnapshot snapshot;
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AiUsageSummary summary = snapshot.summary;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.md,
        ShqSpace.lg,
        ShqSpace.xl,
      ),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _Metric(
                label: '调用次数',
                value: '${summary.calls}',
                icon: Icons.bolt_outlined,
              ),
            ),
            const SizedBox(width: ShqSpace.sm),
            Expanded(
              child: _Metric(
                label: '输入 tokens',
                value: _formatTokens(summary.tokensIn),
                icon: Icons.south_west,
              ),
            ),
            const SizedBox(width: ShqSpace.sm),
            Expanded(
              child: _Metric(
                label: '输出 tokens',
                value: _formatTokens(summary.tokensOut),
                icon: Icons.north_east,
              ),
            ),
          ],
        ),
        const SizedBox(height: ShqSpace.sm),
        Text(
          '合计 ${_formatTokens(summary.tokens)} tokens'
          '${summary.estimatedCalls > 0 ? ' · ${summary.estimatedCalls} 次为估算（端点未返回 usage）' : ''}'
          '${summary.failedCalls > 0 ? ' · ${summary.failedCalls} 次失败' : ''}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.outline,
            height: 1.4,
          ),
        ),
        const SizedBox(height: ShqSpace.lg),
        Text(
          '最近记录',
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: ShqSpace.sm),
        if (snapshot.recent.isEmpty)
          Container(
            padding: const EdgeInsets.all(ShqSpace.lg),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(ShqRadius.md),
            ),
            child: Text(
              '还没有调用记录。配置 AI 后问一道题试试。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final AiUsageRecord record in snapshot.recent) ...<Widget>[
            _UsageRow(record: record),
            const SizedBox(height: ShqSpace.xs),
          ],
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(ShqSpace.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.record});

  final AiUsageRecord record;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final DateTime time = DateTime.fromMillisecondsSinceEpoch(record.at);
    final String timeText =
        '${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    final String task = _taskLabel(record.task);
    final String approx = record.estimated ? '≈ ' : '';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ShqSpace.md,
        vertical: ShqSpace.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(ShqRadius.sm),
        border: Border.all(
          color: record.ok
              ? scheme.outlineVariant
              : scheme.error.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            record.ok ? _taskIcon(record.task) : Icons.error_outline,
            size: 16,
            color: record.ok ? scheme.primary : scheme.error,
          ),
          const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '$task · ${record.model.isEmpty ? '未知模型' : record.model}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium,
                ),
                const SizedBox(height: 1),
                Text(
                  '$timeText${record.ok ? '' : ' · 失败'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: record.ok ? scheme.outline : scheme.error,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: ShqSpace.sm),
          Text(
            '$approx${_formatTokens(record.tokensIn)} / '
            '${_formatTokens(record.tokensOut)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

String _taskLabel(String task) => switch (task) {
  'chat' => '对话',
  'solve' => '先做一遍',
  'grade' => '判题',
  'test' => '连接测试',
  _ => task.isEmpty ? '调用' : task,
};

IconData _taskIcon(String task) => switch (task) {
  'chat' => Icons.chat_bubble_outline,
  'solve' => Icons.lightbulb_outline,
  'grade' => Icons.fact_check_outlined,
  'test' => Icons.network_check,
  _ => Icons.bolt_outlined,
};

String _formatTokens(int value) {
  if (value < 1000) {
    return '$value';
  }
  if (value < 1000000) {
    final double k = value / 1000;
    return '${k.toStringAsFixed(k >= 10 ? 0 : 1)}k';
  }
  final double m = value / 1000000;
  return '${m.toStringAsFixed(m >= 10 ? 0 : 1)}M';
}
