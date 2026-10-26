import 'package:flutter/material.dart';
import 'package:shuaqi/domain/export/export_options.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/ui/bookshelf/workbook_export.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 导出 PDF 的选项浮层（2026-10-25 用户："可以给选项，也可以直接点预设"）。
///
/// 两段式：
/// 1. 上面四个**预设**（纯试卷 / 试卷+笔迹 / 完整存档 / 只要答题卡）——80% 的情况一次点击；
/// 2. 下面三个**开关**——想只要"笔迹但不要答题卡"这种组合时自己拼。
///
/// 开关与预设是同一份数据（[ExportOptions]），点预设 = 把三个开关拨到那个组合，
/// 所以底部"将导出：原题 + 笔迹"永远和开关一致，不会出现"选了预设但实际没变"。
Future<ExportRequest?> showExportOptionsSheet(
  BuildContext context, {
  required Workbook workbook,
}) {
  return showModalBottomSheet<ExportRequest>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
    ),
    builder: (BuildContext context) =>
        _ExportOptionsSheet(title: workbook.title),
  );
}

class _ExportOptionsSheet extends StatefulWidget {
  const _ExportOptionsSheet({required this.title});

  final String title;

  @override
  State<_ExportOptionsSheet> createState() => _ExportOptionsSheetState();
}

class _ExportOptionsSheetState extends State<_ExportOptionsSheet> {
  ExportOptions _options = ExportOptions.withInk;

  /// 打开面板的时刻：文件名里的时间戳固定成这一刻，用户改选项时不跳。
  final DateTime _at = DateTime.now();

  late final TextEditingController _name = TextEditingController(
    text: _defaultName,
  );

  /// 用户手改过文件名后，切换选项不再覆盖他的输入。
  bool _nameDirty = false;

  String get _defaultName =>
      exportFileName(widget.title, _at, options: _options);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _setOptions(ExportOptions next) {
    setState(() {
      _options = next;
      if (!_nameDirty) {
        _name.text = _defaultName;
      }
    });
  }

  void _restoreName() {
    setState(() {
      _nameDirty = false;
      _name.text = _defaultName;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          ShqSpace.xl,
          ShqSpace.xs,
          ShqSpace.xl,
          ShqSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '导出 PDF',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: ShqSpace.lg),
            Wrap(
              spacing: ShqSpace.sm,
              runSpacing: ShqSpace.sm,
              children: <Widget>[
                for (final ({String label, ExportOptions options}) preset
                    in ExportOptions.presets)
                  _PresetChip(
                    label: preset.label,
                    active: _options.matches(preset.options),
                    onTap: () => _setOptions(preset.options),
                  ),
              ],
            ),
            const SizedBox(height: ShqSpace.md),
            _SwitchRow(
              label: ExportPart.original.label,
              hint: ExportPart.original.hint,
              value: _options.original,
              onChanged: () => _toggle(ExportPart.original),
            ),
            _SwitchRow(
              label: ExportPart.ink.label,
              hint: _options.original
                  ? ExportPart.ink.hint
                  : '${ExportPart.ink.hint}（需要原题页）',
              value: _options.effectiveInk,
              enabled: _options.original,
              onChanged: () => _toggle(ExportPart.ink),
            ),
            _SwitchRow(
              label: ExportPart.answer.label,
              hint: ExportPart.answer.hint,
              value: _options.answer,
              onChanged: () => _toggle(ExportPart.answer),
            ),
            const SizedBox(height: ShqSpace.sm),
            // 清晰度（2026-10-26 用户第 14 条）：标准 1700px / 高清 2400px。
            Row(
              children: <Widget>[
                Icon(
                  Icons.high_quality_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: ShqSpace.sm),
                Text('清晰度', style: theme.textTheme.bodySmall),
                const Spacer(),
                for (final ExportQuality quality in ExportQuality.values)
                  Padding(
                    padding: const EdgeInsets.only(left: ShqSpace.xs),
                    child: _PresetChip(
                      label: quality.label,
                      active: _options.quality == quality,
                      onTap: () => _setOptions(
                        _options.copyWith(quality: quality),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: ShqSpace.md),
            // 文件名（2026-10-26 用户：导出名要能看出导的是什么，且可改）。
            TextField(
              controller: _name,
              maxLength: 90,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: '文件名',
                helperText: '默认带「内容 + 时间」；可改，.pdf 会自动补',
                counterText: '',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: '恢复默认文件名',
                  onPressed: _restoreName,
                  icon: const Icon(Icons.restart_alt, size: 18),
                ),
              ),
              onChanged: (String value) {
                _nameDirty = value.trim() != _defaultName;
              },
            ),
            const SizedBox(height: ShqSpace.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: ShqSpace.md,
                vertical: ShqSpace.sm,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(ShqRadius.md),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.picture_as_pdf_outlined,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: ShqSpace.sm),
                  Expanded(
                    child: Text(
                      '将导出：${_options.summary}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: ShqSpace.md),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: ShqSpace.md),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _options.canExport
                        ? () => Navigator.pop(
                            context,
                            ExportRequest(
                              options: _options,
                              fileName: _name.text.trim(),
                            ),
                          )
                        : null,
                    icon: const Icon(Icons.file_download_outlined, size: 18),
                    label: const Text('导出到下载'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _toggle(ExportPart part) => _setOptions(_options.toggle(part));
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: ShqMotion.instant,
        padding: const EdgeInsets.symmetric(
          horizontal: ShqSpace.md,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: active ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShqRadius.pill),
          border: Border.all(
            color: active ? scheme.primary : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: active ? scheme.onPrimaryContainer : scheme.onSurface,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final String hint;
  final bool value;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return InkWell(
      onTap: enabled ? onChanged : null,
      borderRadius: BorderRadius.circular(ShqRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: ShqSpace.xs),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: enabled ? scheme.onSurface : scheme.outline,
                    ),
                  ),
                  Text(
                    hint,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: enabled ? (_) => onChanged() : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 导出进度弹窗：一句"在做什么" + 一条进度 + 一句"别退出"。
///
/// 不做百分比假进度：总量里"答题卡"的页数要边渲染边定，
/// 所以有确定总数时给线性进度，没有就给不确定态（转圈），不编数字。
class ExportProgressDialog extends StatelessWidget {
  const ExportProgressDialog({
    super.key,
    required this.title,
    required this.progress,
  });

  final String title;
  final ValueNotifier<ExportProgress> progress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('正在导出 PDF'),
        content: ValueListenableBuilder<ExportProgress>(
          valueListenable: progress,
          builder: (BuildContext context, ExportProgress value, Widget? child) {
            final double? fraction = value.fraction;
            return SizedBox(
              width: 340,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: ShqSpace.md),
                  Text(
                    value.stage,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: ShqSpace.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(ShqRadius.pill),
                    child: LinearProgressIndicator(
                      value: fraction,
                      minHeight: 6,
                      backgroundColor: scheme.surfaceContainerHigh,
                    ),
                  ),
                  const SizedBox(height: ShqSpace.sm),
                  Text(
                    '渲染期间请不要退出；页数多时需要十几秒。',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
