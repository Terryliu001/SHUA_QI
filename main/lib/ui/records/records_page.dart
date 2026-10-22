import 'package:flutter/material.dart';
import 'package:shuaqi/ui/widgets/empty_state.dart';

/// 记录 tab（T7.1 会话列表的占位）。
///
/// **刻意占位**：交卷状态机（T5.5）还没做，这里先给一个诚实的空态，
/// 而不是放一份假数据。做出来时把本文件换成真列表即可。
class RecordsPage extends StatelessWidget {
  const RecordsPage({super.key, required this.onGoBookshelf});

  final VoidCallback onGoBookshelf;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('记录')),
      body: EmptyState(
        icon: Icons.assignment_outlined,
        title: '还没有提交记录',
        message: '交卷后，每一次作答的过程记录都会出现在这里',
        actionLabel: '去书架',
        onAction: onGoBookshelf,
      ),
    );
  }
}
