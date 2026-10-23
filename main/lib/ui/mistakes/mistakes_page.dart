import 'package:flutter/material.dart';
import 'package:shuaqi/ui/widgets/feature_preview_page.dart';

/// 错题本 tab（T7.2 的**诚实预览**）。
///
/// 判题引擎（T5.4）还没做，这里不放假数据；但页面本身把"错题本是干什么的"
/// 讲清楚。INV-05 的精神也在这里：不预设评判语气，存疑与做错分开对待。
class MistakesPage extends StatelessWidget {
  const MistakesPage({super.key, required this.onGoBookshelf});

  final VoidCallback onGoBookshelf;

  @override
  Widget build(BuildContext context) {
    return FeaturePreviewPage(
      appBarTitle: '错题本',
      icon: Icons.grade_outlined,
      headline: '错题不是判决，是待复核',
      message: '标记为存疑或做错的题会收进这里，随时回看原卷与当时的笔迹。',
      onGoBookshelf: onGoBookshelf,
      items: const <FeaturePreviewItem>[
        FeaturePreviewItem(
          icon: Icons.fact_check_outlined,
          title: '待复核题',
          description: '判为存疑或做错的题自动收进来，不预设结论',
        ),
        FeaturePreviewItem(
          icon: Icons.draw_outlined,
          title: '原卷 + 笔迹',
          description: '每道题都带着当时的作答笔迹，不丢上下文',
        ),
        FeaturePreviewItem(
          icon: Icons.repeat_outlined,
          title: '二刷',
          description: '按知识点重做；二刷对比视图安排在 v1.1',
        ),
      ],
    );
  }
}
