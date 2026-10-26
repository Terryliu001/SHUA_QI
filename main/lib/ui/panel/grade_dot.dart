import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 判题三色的唯一取色入口。
///
/// 浅色用 [ShqPalette] 的语义色；暗色主题下它们太深（在 #191612 上几乎看不见），
/// 换成 [ShqRegion] 里那组提亮版——**颜色值相同语义**，只是为对比度调的。
Color gradeColor(BuildContext context, AnswerVerdict verdict) {
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  switch (verdict) {
    case AnswerVerdict.correct:
      return dark ? ShqRegion.greenOnDark : ShqPalette.correct;
    case AnswerVerdict.pending:
      return dark ? ShqRegion.yellowOnDark : ShqPalette.unclear;
    case AnswerVerdict.wrong:
      return dark ? ShqRegion.redOnDark : ShqPalette.wrong;
    case AnswerVerdict.none:
      return Theme.of(context).colorScheme.outline;
  }
}

String gradeLabel(AnswerVerdict verdict) {
  switch (verdict) {
    case AnswerVerdict.correct:
      return '对';
    case AnswerVerdict.pending:
      return '待判';
    case AnswerVerdict.wrong:
      return '错';
    case AnswerVerdict.none:
      return '未判';
  }
}

/// 判题状态点（用户第 9 条：每题一个红黄绿圆形指示，可点手动改）。
///
/// `none` 画成空心灰圈而不是不画：列表里每行的"这个位置有判题状态"
/// 需要对齐，空着会让题号位置抖动；空心圈也明确表示"还没判"。
class GradeDot extends StatelessWidget {
  const GradeDot({
    super.key,
    required this.verdict,
    this.size = 9,
    this.onChanged,
  });

  final AnswerVerdict verdict;
  final double size;

  /// 点一下改判；null = 只读（例如批量条里的统计点）。
  final ValueChanged<AnswerVerdict>? onChanged;

  @override
  Widget build(BuildContext context) {
    final Color color = gradeColor(context, verdict);
    final Widget dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: verdict == AnswerVerdict.none ? Colors.transparent : color,
        shape: BoxShape.circle,
        border: Border.all(
          color: verdict == AnswerVerdict.none
              ? color.withValues(alpha: 0.7)
              : color,
          width: 1.4,
        ),
      ),
    );
    if (onChanged == null) {
      return Tooltip(message: gradeLabel(verdict), child: dot);
    }
    return Semantics(
      button: true,
      label: '判题状态：${gradeLabel(verdict)}，点按修改',
      child: Tooltip(
        message: '${gradeLabel(verdict)} · 点按修改',
        child: InkResponse(
          onTap: () => _openMenu(context),
          radius: 16,
          child: Padding(padding: const EdgeInsets.all(4), child: dot),
        ),
      ),
    );
  }

  Future<void> _openMenu(BuildContext context) async {
    final RenderBox box = context.findRenderObject() as RenderBox;
    final Offset topLeft = box.localToGlobal(Offset.zero);
    final AnswerVerdict? picked = await showMenu<AnswerVerdict>(
      context: context,
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        topLeft.dy + box.size.height,
        topLeft.dx + 1,
        0,
      ),
      items: <PopupMenuEntry<AnswerVerdict>>[
        for (final AnswerVerdict value in AnswerVerdict.values)
          PopupMenuItem<AnswerVerdict>(
            value: value,
            child: Row(
              children: <Widget>[
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: value == AnswerVerdict.none
                        ? Colors.transparent
                        : gradeColor(context, value),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: gradeColor(context, value),
                      width: 1.4,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(gradeLabel(value)),
                if (value == verdict) ...<Widget>[
                  const Spacer(),
                  const Icon(Icons.check, size: 15),
                ],
              ],
            ),
          ),
      ],
    );
    if (picked != null && picked != verdict) {
      onChanged?.call(picked);
    }
  }
}
