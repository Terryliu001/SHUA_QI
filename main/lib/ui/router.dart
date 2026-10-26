import 'package:flutter/material.dart';
import 'package:shuaqi/ui/favorites/favorite_redo_page.dart';
import 'package:shuaqi/ui/favorites/favorite_set_page.dart';
import 'package:shuaqi/ui/favorites/favorite_workbook_page.dart';
import 'package:shuaqi/ui/favorites/question_view_page.dart';
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
  static const String favoriteQuestion = '/favorite_question';
  static const String favoriteWorkbook = '/favorite_workbook';
  static const String favoriteSet = '/favorite_set';
  static const String favoriteRedo = '/favorite_redo';

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case shell:
        return MaterialPageRoute<void>(
          builder: (BuildContext context) => const AppShell(),
          settings: settings,
        );
      case reader:
        final Object? arguments = settings.arguments;
        final ReaderRouteArgs? args = arguments is ReaderRouteArgs
            ? arguments
            : null;
        return MaterialPageRoute<void>(
          builder: (BuildContext context) => ReaderPage(
            workbookId: args?.workbookId ?? '',
            initialQuestionId: args?.initialQuestionId,
          ),
          settings: settings,
        );
      case favoriteQuestion:
        final Object? arguments = settings.arguments;
        final String favoriteId = arguments is QuestionViewArgs
            ? arguments.favoriteId
            : '';
        return MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              QuestionViewPage(favoriteId: favoriteId),
          settings: settings,
        );
      case favoriteSet:
        final Object? arguments = settings.arguments;
        final String setId = arguments is FavoriteSetArgs ? arguments.setId : '';
        return MaterialPageRoute<void>(
          builder: (BuildContext context) => FavoriteSetPage(setId: setId),
          settings: settings,
        );
      case favoriteWorkbook:
        final Object? arguments = settings.arguments;
        final FavoriteWorkbookArgs? args = arguments is FavoriteWorkbookArgs
            ? arguments
            : null;
        return MaterialPageRoute<void>(
          builder: (BuildContext context) => FavoriteWorkbookPage(
            workbookId: args?.workbookId ?? '',
            title: args?.title ?? '',
          ),
          settings: settings,
        );
      case favoriteRedo:
        final Object? arguments = settings.arguments;
        final RedoArgs args = arguments is RedoArgs
            ? arguments
            : const RedoArgs(favoriteIds: <String>[], title: '重刷');
        return MaterialPageRoute<void>(
          builder: (BuildContext context) => FavoriteRedoPage(args: args),
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
  const ReaderRouteArgs({required this.workbookId, this.initialQuestionId});

  final String workbookId;

  /// 打开后定位并选中这道题（收藏夹「回看出处」用）；null = 正常打开。
  final String? initialQuestionId;
}
