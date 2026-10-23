import 'package:flutter/material.dart';
import 'package:shuaqi/ui/widgets/feature_preview_page.dart';

/// 记录 tab（T7.1 会话列表的**诚实预览**）。
///
/// 交卷状态机（T5.5）还没做，所以这里不做假列表；但也不该只是一句"暂无"——
/// 用一页说清"将来会有什么"，让空态本身有信息。
class RecordsPage extends StatelessWidget {
  const RecordsPage({super.key, required this.onGoBookshelf});

  final VoidCallback onGoBookshelf;

  @override
  Widget build(BuildContext context) {
    return FeaturePreviewPage(
      appBarTitle: '记录',
      icon: Icons.assignment_outlined,
      headline: '每一次作答，都留得住',
      message: '交卷之后，这里会有时间线、得分与回看入口。现在先把书架用起来。',
      onGoBookshelf: onGoBookshelf,
      items: const <FeaturePreviewItem>[
        FeaturePreviewItem(
          icon: Icons.timeline,
          title: '作答时间线',
          description: '哪天、哪一卷、做了多久，按卷子归档',
        ),
        FeaturePreviewItem(
          icon: Icons.rule_outlined,
          title: '对 / 存疑 / 错 分开记',
          description: '客观题三态判题；存疑不等于错，语气保持中性',
        ),
        FeaturePreviewItem(
          icon: Icons.history_edu_outlined,
          title: '一键回到原卷',
          description: '从记录跳到当时那一页，笔迹与标记都还在',
        ),
      ],
    );
  }
}
