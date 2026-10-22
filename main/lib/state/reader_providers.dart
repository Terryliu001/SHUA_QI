import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/domain/model/session.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/infra/db/dao/page_dao.dart';
import 'package:shuaqi/infra/db/dao/session_dao.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/infra/pdf/pdfrx_source.dart';
import 'package:shuaqi/state/app_providers.dart';

/// 阅读器打开一卷所需的全部东西。
class ReaderHandle {
  const ReaderHandle({
    required this.workbook,
    required this.pages,
    required this.source,
    required this.session,
    required this.sessionDao,
  });

  final Workbook workbook;
  final List<WbPage> pages;
  final PdfrxSource source;

  /// 当前 draft 会话（没有就新建）。进度写在它上面。
  final Session session;
  final SessionDao sessionDao;

  Future<void> saveLastPage(int page) =>
      sessionDao.updateLastPage(session.id, page);
}

/// 打开一卷：读卷与页 → 打开 PDF → 取/建 draft 会话 → 记一次"已打开"。
///
/// 用 `FutureProvider.family` 而不是在页面里手动管理：离开页面时 Riverpod 会自动
/// dispose，PDF 句柄跟着释放（避免"退出阅读器后 pdfium 内存不还"）。
final readerHandleProvider =
    FutureProvider.family<ReaderHandle, String>((Ref ref, String workbookId) async {
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      final int now = DateTime.now().toUtc().millisecondsSinceEpoch;

      final WorkbookDao books = WorkbookDao(deps.db.raw);
      final Workbook? workbook = await books.byId(workbookId);
      if (workbook == null) {
        throw StateError('卷不存在：$workbookId');
      }

      final List<WbPage> pages = await PageDao(deps.db.raw).pagesOf(workbookId);
      if (pages.isEmpty) {
        throw StateError('这一卷没有任何页记录，可能导入未完成');
      }

      final PdfrxSource source = await PdfrxSource.openFile(
        deps.vault.file(workbook.sourcePath).path,
      );
      ref.onDispose(() {
        unawaited(source.dispose());
      });

      final SessionDao sessionDao = SessionDao(deps.db.raw);
      Session? session = await sessionDao.latestForWorkbook(workbookId);
      if (session == null || session.state != SessionState.draft) {
        session = await sessionDao.createDraft(workbookId, now: now);
      }

      // 书架"最近打开"排序依赖它
      await books.touchOpened(workbookId, now, session.id);

      return ReaderHandle(
        workbook: workbook,
        pages: pages,
        source: source,
        session: session,
        sessionDao: sessionDao,
      );
    });
