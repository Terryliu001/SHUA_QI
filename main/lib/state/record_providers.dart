import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/app/records/profile_store.dart';
import 'package:shuaqi/app/records/record_service.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/domain/model/question_kind.dart';
import 'package:shuaqi/domain/model/shelf_folder.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/records/answer_log.dart';
import 'package:shuaqi/domain/records/record_time.dart';
import 'package:shuaqi/domain/records/records_overview.dart';
import 'package:shuaqi/domain/records/records_stats.dart';
import 'package:shuaqi/infra/db/dao/answer_log_dao.dart';
import 'package:shuaqi/infra/db/dao/folder_dao.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/state/app_providers.dart';

/// 热力图覆盖的周数（半年）。
///
/// 26 列在 2/5 栏宽（平板约 460dp）里正好：11dp 格子 + 3dp 间隙 = 14dp，
/// 26 × 14 = 364dp，加上左侧星期标签与边距刚好留白。
const int kHeatWeeks = 26;

/// 词云统计窗口（天）。比看板的 30 天长，因为"科目结构"要看一段时间的积累。
const int kCloudDays = 90;

/// **今天**（本地日期）。
///
/// 2026-10-26 用户第 8 条：热力图的"今天"原来取自 `overview.generatedAt`
/// （provider 不刷新就一直停在旧日期），跨零点或隔天再看会错位。
/// 这里给一个**会自己走**的今天：
/// - 页面每次进入 / 刷新时重算；
/// - 到了零点自动切换；
/// - 应用从后台回到前台时校正一次（用户可能跨天开着 app）。
final NotifierProvider<RecordsTodayController, DateTime> recordsTodayProvider =
    NotifierProvider<RecordsTodayController, DateTime>(
      RecordsTodayController.new,
    );

class RecordsTodayController extends Notifier<DateTime> {
  Timer? _timer;

  /// 生命周期监听（回到前台时校正"今天"）。
  ///
  /// 用 [AppLifecycleListener] 而不是 `WidgetsBindingObserver`：
  /// `Notifier` 不能再混进别的接口，而 AppLifecycleListener 就是一个
  /// 可以自己 new、自己 dispose 的小对象。
  AppLifecycleListener? _lifecycle;

  @override
 DateTime build() {
    final DateTime now = RecordTime.dateOnly(DateTime.now());
    _scheduleMidnight(now);
    _lifecycle = AppLifecycleListener(onResume: _refreshNow);
    ref.onDispose(() {
      _timer?.cancel();
      _lifecycle?.dispose();
    });
    return now;
  }

  /// 零点后 1 秒重算一次：跨天时"今天"要跟着走。
  void _scheduleMidnight(DateTime now) {
    _timer?.cancel();
    final DateTime next = DateTime(
      now.year,
      now.month,
      now.day + 1,
      0,
      0,
      1,
    );
    final Duration delay = next.difference(DateTime.now());
    _timer = Timer(delay.isNegative ? const Duration(seconds: 1) : delay, () {
      final DateTime fresh = RecordTime.dateOnly(DateTime.now());
      if (fresh != state) {
        state = fresh;
      }
      _scheduleMidnight(fresh);
    });
  }

  /// 回到前台 / 手动刷新时重算"今天"。
  void _refreshNow() {
    final DateTime fresh = RecordTime.dateOnly(DateTime.now());
    if (fresh != state) {
      state = fresh;
    }
    _scheduleMidnight(fresh);
  }

  /// 手动刷新（下拉刷新 / 切 tab）。
  void refresh() => _refreshNow();
}

/// 热力图显示的周数（13 / 26 / 52）。
///
/// 用户第 8 条："做好显示数量上限设置"。默认 26 周（半年）。
final NotifierProvider<HeatWeeksController, int> heatWeeksProvider =
    NotifierProvider<HeatWeeksController, int>(HeatWeeksController.new);

class HeatWeeksController extends Notifier<int> {
  static const List<int> options = <int>[13, 26, 52];
  static const int fallback = 26;

  late final SettingDao _dao;

  @override
  int build() {
    _dao = SettingDao(ref.watch(appDependenciesProvider).db.raw);
    unawaited(_load());
    return fallback;
  }

  Future<void> _load() async {
    final String? raw = await _dao.get(AppSettingKeys.recordsHeatWeeks);
    final int value = int.tryParse(raw ?? '') ?? fallback;
    state = options.contains(value) ? value : fallback;
  }

  Future<void> set(int weeks) async {
    if (!options.contains(weeks) || weeks == state) {
      return;
    }
    state = weeks;
    await _dao.put(AppSettingKeys.recordsHeatWeeks, '$weeks');
  }
}

/// 作答记录写入入口。四个打点位置（答题卡 / 判题 / 收藏 / 重刷）共用它。
final Provider<RecordService> recordServiceProvider = Provider<RecordService>((
  Ref ref,
) {
  return RecordService(db: ref.watch(appDependenciesProvider).db);
});

/// 个人空间的数据源（昵称 / 格言 / 头像 / 封面）。
final Provider<ProfileStore> profileStoreProvider = Provider<ProfileStore>((
  Ref ref,
) {
  final AppDependencies deps = ref.watch(appDependenciesProvider);
  return ProfileStore(db: deps.db, vault: deps.vault);
});

final FutureProvider<ProfileData> profileProvider =
    FutureProvider<ProfileData>((Ref ref) {
      return ref.watch(profileStoreProvider).load();
    });

/// 记录页首屏的全部数据（一次装配）。
///
/// 刷新时机（`ui/records/records_page.dart`）：
/// - 页面首次构建；
/// - 切回「记录」tab（`shellTabProvider`）；
/// - 下拉刷新；
/// - 从时间线/阅读器返回。
final FutureProvider<RecordsOverview> recordsOverviewProvider =
    FutureProvider<RecordsOverview>((Ref ref) async {
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      final AnswerLogDao log = AnswerLogDao(deps.db.raw);
      final DateTime now = DateTime.now();
      final DateTime today = RecordTime.dateOnly(now);
      final DateTime heatStart = RecordTime.addDays(
        RecordTime.mondayOf(today),
        -(kHeatWeeks - 1) * 7,
      );
      final DateTime weekFrom = RecordTime.addDays(today, -6);
      final DateTime monthFrom = RecordTime.addDays(today, -29);
      final DateTime cloudFrom = RecordTime.addDays(today, -(kCloudDays - 1));

      final Map<String, DayStat> dayStats = await log.dayStats(
        sinceDay: RecordTime.dayKey(heatStart),
      );
      final List<AnswerLogEntry> entries = await log.listAll(
        sinceDay: RecordTime.dayKey(cloudFrom),
      );
      final int totalQuestions = await log.totalQuestions();
      final int activeDays = await log.activeDays();
      final int totalWorkbooks = await log.totalWorkbooks();

      final Map<String, int> questionsByWorkbook = await log.questionsByWorkbook(
        sinceDay: RecordTime.dayKey(cloudFrom),
      );
      final Map<String, int> questionsByKind = await log.questionsByKind(
        sinceDay: RecordTime.dayKey(cloudFrom),
      );

      final List<Workbook> workbooks = await WorkbookDao(
        deps.db.raw,
      ).listByRecent(limit: 100000);
      final List<ShelfFolder> folders = await FolderDao(deps.db.raw).list();
      final Map<String, String> folderNameById = <String, String>{
        for (final ShelfFolder folder in folders) folder.id: folder.name,
      };
      final Map<String, String> folderIdOfWorkbook = <String, String>{
        for (final Workbook workbook in workbooks) workbook.id: workbook.folderId,
      };

      // 按科目（文件夹）汇总：题数累加、卷数按卷去重。
      // 口径：每层文件夹各算一个词（见 subjectWordsFrom 的注释）。
      final List<CloudWord> subjectWords = subjectWordsFrom(
        questionsByWorkbook: questionsByWorkbook,
        folderIdOfWorkbook: folderIdOfWorkbook,
        folderNameById: folderNameById,
      );

      final List<CloudWord> kindWords = buildCloudWords(<CloudBucket>[
        for (final MapEntry<String, int> entry in questionsByKind.entries)
          CloudBucket(
            label: questionKindCloudLabel(entry.key),
            questions: entry.value,
          ),
      ]);

      return RecordsOverview(
        generatedAt: now,
        dayStats: dayStats,
        week: summarize(entries, from: weekFrom, to: today),
        month: summarize(entries, from: monthFrom, to: today),
        streak: currentStreak(dayStats, today: today),
        totalQuestions: totalQuestions,
        activeDays: activeDays,
        totalWorkbooks: totalWorkbooks,
        subjectWords: subjectWords,
        kindWords: kindWords,
      );
    });

/// 作答时间线（按时间倒序，最多 [limit] 条）。
///
/// 400 条足够覆盖"最近几周的记录"；再往上翻是考古，不是这个页面的定位。
final FutureProvider<List<TimelineDay>> recordsTimelineProvider =
    FutureProvider<List<TimelineDay>>((Ref ref) async {
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      final List<AnswerLogEntry> entries = await AnswerLogDao(
        deps.db.raw,
      ).list(limit: 400);
      final List<Workbook> workbooks = await WorkbookDao(
        deps.db.raw,
      ).listByRecent(limit: 100000);
      return groupTimeline(
        entries,
        existingWorkbookIds: <String>{
          for (final Workbook workbook in workbooks) workbook.id,
        },
        liveTitles: <String, String>{
          for (final Workbook workbook in workbooks) workbook.id: workbook.title,
        },
      );
    });
