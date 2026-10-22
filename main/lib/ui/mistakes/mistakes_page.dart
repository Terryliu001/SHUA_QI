import 'package:flutter/material.dart';
import 'package:shuaqi/ui/widgets/empty_state.dart';

/// 错题本 tab（T7.2 的占位）。
///
/// **刻意占位**：判题引擎（T5.4）还没做，先给诚实空态。
/// INV-05 的精神也体现在这里：错题本的入口文案不说"错题"之外的话，
/// 不预设任何评判语气。
class MistakesPage extends StatelessWidget {
  const MistakesPage({super.key, required this.onGoBookshelf});

  final VoidCallback onGoBookshelf;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('错题本')),
      body: EmptyState(
        icon: Icons.grade_outlined,
        title: '错题本还是空的',
        message: '交卷后，标记为待复核的题会收进这里，可随时回看原卷与笔迹',
        actionLabel: '去书架',
        onAction: onGoBookshelf,
      ),
    );
  }
}
