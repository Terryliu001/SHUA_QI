import 'package:flutter/material.dart';
import 'package:shuaqi/ui/reader/reader_page.dart';
import 'package:shuaqi/ui/shell/app_shell.dart';

/// 路由表。
///
/// 用 Navigator 1.0 的 `onGenerateRoute`，不引入 go_router ——
/// 后者不在白名单（§5.3 依赖白名单），而且本项目只有 6 个页面，手写表更可控。
///
/// 顶层只有一条路由：外壳（四个主 tab）。tab 切换是外壳内部状态，
/// 不进路由栈——否则系统返回键会一级级退 tab，而不是直接退出阅读器。
abstract final class AppRoutes {
  static const String shell = '/';
  static const String reader = '/reader';

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case shell:
        return MaterialPageRoute<void>(
          builder: (BuildContext context) => const AppShell(),
          settings: settings,
        );
      case reader:
        final Object? arguments = settings.arguments;
        final String workbookId = arguments is ReaderRouteArgs
            ? arguments.workbookId
            : '';
        return MaterialPageRoute<void>(
          builder: (BuildContext context) => ReaderPage(workbookId: workbookId),
          settings: settings,
        );
      default:
        // 未知路由返回 null，由 Navigator 抛标准错误——不要自己吞掉。
        return null;
    }
  }
}

/// 进入阅读器必须带卷 id。做成类型而不是裸 Map，是为了能在编译期发现漏传。
class ReaderRouteArgs {
  const ReaderRouteArgs({required this.workbookId});

  final String workbookId;
}
