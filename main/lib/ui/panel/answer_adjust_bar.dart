import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 从答题卡点「重框」回到原卷时，左上角的调整浮条。
///
/// ## 2026-10-26 重设计（用户第 12 条：提示键"不太明显不太美观"）
/// 旧版是一颗药丸：题号 + 「拖框调整」+「停留」+「返回」。问题有三个：
/// 1. 「返回 / 停留」两个词没有主次，用户不知道点哪个；
/// 2. 看不出**当前在调什么**（切题框 vs 作答框）；
/// 3. 改完有没有存下来，界面上一个字都没有。
///
/// 现在：
/// - 标题写明「调整切题框」——一眼知道在动什么；
/// - 主按钮「完成 · 回答题卡」/ 次按钮「留在原卷」：主次分明，动词开头；
/// - 右侧常驻「已自动保存 HH:mm」：改完不用点保存，也不怕丢；
/// - 形状从药丸改成圆角卡片 + 发丝边 + 投影，浮在纸上更清楚（不抢题面）。
class AnswerAdjustBar extends StatelessWidget {
  const AnswerAdjustBar({
    super.key,
    required this.label,
    required this.onBack,
    required this.onStay,
    this.savedAt,
    this.saving = false,
  });

  /// 题号（"12." 这种），让用户确认在调哪一道。
  final String label;

  /// 保存 + 重算 + 回答题卡继续写这道题。
  final VoidCallback onBack;

  /// 保存并留在阅读器（浮条消失）。
  final VoidCallback onStay;

  /// 最近一次自动保存的时刻（null = 还没保存过）。
  final DateTime? savedAt;

  /// 正在保存（按钮禁用 + 显示"保存中"）。
  final bool saving;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? stamp = _stampOf(savedAt);
    return Material(
      elevation: 8,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(ShqRadius.md),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ShqRadius.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ShqSpace.md,
          ShqSpace.sm,
          ShqSpace.sm,
          ShqSpace.sm,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              constraints: const BoxConstraints(minWidth: 24),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: ShqRegion.answer.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(ShqRadius.sm),
              ),
              child: Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: ShqRegion.answer,
                  fontWeight: FontWeight.w700,
                  fontSize: ShqType.caption,
                ),
              ),
            ),
            const SizedBox(width: ShqSpace.sm),
            Text(
              '调整切题框',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: ShqSpace.sm),
            // 自动保存状态：让"改了就存了"这件事可见。
            Icon(
              saving ? Icons.sync : Icons.check_circle_outline,
              size: 13,
              color: saving ? scheme.outline : scheme.primary,
            ),
            const SizedBox(width: 3),
            Text(
              saving
                  ? '保存中…'
                  : (stamp == null ? '改动会自动保存' : '已保存 $stamp'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: saving ? scheme.outline : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: ShqSpace.sm),
            TextButton(
              onPressed: saving ? null : onStay,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm),
                visualDensity: VisualDensity.compact,
                foregroundColor: scheme.onSurfaceVariant,
              ),
              child: const Text('留在原卷'),
            ),
            FilledButton.icon(
              onPressed: saving ? null : onBack,
              icon: const Icon(Icons.check, size: 16),
              label: const Text('完成 · 回答题卡'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: ShqSpace.md),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `12:34`（只到分钟：秒级对用户没有意义，反而更吵）。
  static String? _stampOf(DateTime? at) {
    if (at == null) {
      return null;
    }
    final String h = at.hour.toString().padLeft(2, '0');
    final String m = at.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
