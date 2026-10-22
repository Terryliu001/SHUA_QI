import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 书架（T1.4 落地，这里只是路由可达的最小占位）。
///
/// 存在的意义有两个：
/// 1. 让 `initialRoute` 有落点，骨架能真的启动；
/// 2. 提供一个能触发路由跳转的入口，用来验证「路由 + 主题」是通的。
///
/// 真实的书架（列表 / 进度 / 最近打开 / 空态 / 长按菜单）不在本任务范围内。
class BookshelfPage extends StatelessWidget {
  const BookshelfPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('书架')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ShqLayout.maxReadingWidth),
          child: Padding(
            padding: const EdgeInsets.all(ShqSpace.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('刷起 SHUAQI', style: theme.textTheme.headlineSmall),
                const SizedBox(height: ShqSpace.sm),
                Text(
                  'T1.1 骨架已就位：主题、路由、Riverpod、错误兜底。\n'
                  '书架列表见 T1.4，PDF 导入见 T1.3。',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: ShqSpace.xl),
                FilledButton(
                  onPressed: () => unawaited(
                    Navigator.of(context).pushNamed(
                      AppRoutes.reader,
                      arguments: const ReaderRouteArgs(workbookId: 'wb_demo'),
                    ),
                  ),
                  child: const Text('打开示例阅读器（验证路由与主题）'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
