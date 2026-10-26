import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 编辑一道收藏题的知识点（多选已有 + 新建 + 清空）。
///
/// 为什么做成"标签多选 + 新建"而不是纯文本逗号输入：
/// - 自由文本让同义标签分裂（三角函数/三角/三角公式），批量检索就废了；
/// - 已有标签以 chip 呈现，用户一眼看到自己维护的词汇表；
/// - 清空保存 = 回到「未归纳」，不需要另设"删除标签"。
///
/// 返回 `null` = 取消；返回空列表 = 明确清空（未归纳）。
Future<List<String>?> showFavoriteTagEditor(
  BuildContext context, {
  required List<String> initial,
  required List<String> suggestions,
}) {
  return showDialog<List<String>>(
    context: context,
    builder: (BuildContext context) => _FavoriteTagEditor(
      initial: initial,
      suggestions: suggestions,
    ),
  );
}

class _FavoriteTagEditor extends StatefulWidget {
  const _FavoriteTagEditor({required this.initial, required this.suggestions});

  final List<String> initial;
  final List<String> suggestions;

  @override
  State<_FavoriteTagEditor> createState() => _FavoriteTagEditorState();
}

class _FavoriteTagEditorState extends State<_FavoriteTagEditor> {
  late final Set<String> _selected = <String>{...widget.initial};
  late final List<String> _extra = <String>[];
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  List<String> get _all =>
      <String>{...widget.suggestions, ...widget.initial, ..._extra}.toList();

  void _addFromInput() {
    final List<String> parsed = _splitTags(_input.text);
    if (parsed.isEmpty) {
      return;
    }
    setState(() {
      for (final String tag in parsed) {
        if (!_all.contains(tag)) {
          _extra.add(tag);
        }
        _selected.add(tag);
      }
      _input.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return AlertDialog(
      title: Text(
        _selected.isEmpty ? '知识点（未归纳）' : '知识点 · ${_selected.length}',
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_all.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: ShqSpace.sm),
                  child: Text(
                    '还没有知识点，输入一个再回车。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              Wrap(
                spacing: ShqSpace.sm,
                runSpacing: ShqSpace.sm,
                children: <Widget>[
                  for (final String tag in _all)
                    FilterChip(
                      label: Text(tag),
                      selected: _selected.contains(tag),
                      onSelected: (bool value) => setState(() {
                        if (value) {
                          _selected.add(tag);
                        } else {
                          _selected.remove(tag);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: ShqSpace.md),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _input,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        hintText: '新建知识点，如：三角函数（可逗号分隔）',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _addFromInput(),
                    ),
                  ),
                  const SizedBox(width: ShqSpace.sm),
                  IconButton(
                    tooltip: '添加',
                    onPressed: _addFromInput,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              const SizedBox(height: ShqSpace.xs),
              Text(
                '保存时不选任何标签 = 回到「未归纳」。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, _selected.toList(growable: false)),
          child: Text(_selected.isEmpty ? '保存为未归纳' : '保存 ${_selected.length} 个'),
        ),
      ],
    );
  }
}

/// 与 [KnowledgeTags.parse] 同一套分隔规则（这里不 import domain，避免 UI 反向依赖）。
List<String> _splitTags(String raw) {
  final List<String> out = <String>[];
  for (final String chunk in raw.split(RegExp(r'[,，、;；]'))) {
    final String t = chunk.trim();
    if (t.isEmpty || out.contains(t)) {
      continue;
    }
    out.add(t.length > 20 ? t.substring(0, 20) : t);
    if (out.length >= 5) {
      break;
    }
  }
  return out;
}
