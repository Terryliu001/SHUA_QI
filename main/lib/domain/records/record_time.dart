/// 记录页的时间口径与中文文案（纯 Dart）。
///
/// 项目没有 `intl`（白名单外），所以日期/星期/时刻都得自己拼。
/// 集中在这里是为了让"今天/昨天"这种相对说法只有一个实现，
/// 热力图、时间线、卡片角标不会各说各话。
library;

abstract final class RecordTime {
  /// 星期一到星期日（`DateTime.weekday` 是 1..7）。
  static const List<String> weekdayNames = <String>[
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
    '日',
  ];

  /// 只保留年月日（本地时区），时分秒归零。
  static DateTime dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// 本地日期 key：`2026-10-25`。
  ///
  /// 用字符串而不是时间戳做分桶键：SQL 里按天 GROUP BY 不需要时区函数，
  /// 而且字典序就是时间序。
  static String dayKey(DateTime local) {
    final String m = local.month.toString().padLeft(2, '0');
    final String d = local.day.toString().padLeft(2, '0');
    return '${local.year}-$m-$d';
  }

  /// 解析 [dayKey]。坏字符串回落 1970-01-01（不抛，记录页不该因为一行脏数据白屏）。
  static DateTime parseDayKey(String key) {
    final List<String> parts = key.split('-');
    if (parts.length != 3) {
      return DateTime(1970);
    }
    final int? y = int.tryParse(parts[0]);
    final int? m = int.tryParse(parts[1]);
    final int? d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) {
      return DateTime(1970);
    }
    return DateTime(y, m, d);
  }

  /// 加减天数：走日历构造而不是 `Duration`，跨月跨年不会错位。
  static DateTime addDays(DateTime day, int delta) =>
      DateTime(day.year, day.month, day.day + delta);

  /// 这一天所在周的周一。
  static DateTime mondayOf(DateTime day) =>
      addDays(dateOnly(day), -(day.weekday - 1));

  /// `10月24日`
  static String monthDay(DateTime local) => '${local.month}月${local.day}日';

  /// `10月24日 周四`
  static String monthDayWeekday(DateTime local) =>
      '${monthDay(local)} 周${weekdayNames[local.weekday - 1]}';

  /// `周四`
  static String weekday(DateTime local) => '周${weekdayNames[local.weekday - 1]}';

  /// `09:05`
  static String clock(DateTime local) {
    final String h = local.hour.toString().padLeft(2, '0');
    final String m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// 相对日期：今天 / 昨天 / `10月24日`。时间线分组头用它。
  static String relativeDay(DateTime local, {required DateTime today}) {
    final int diff = dateOnly(today).difference(dateOnly(local)).inDays;
    if (diff == 0) {
      return '今天';
    }
    if (diff == 1) {
      return '昨天';
    }
    if (diff == 2) {
      return '前天';
    }
    return monthDay(local);
  }

  /// 卡片上的时间：`今天 14:05`。
  static String relativeStamp(DateTime local, {required DateTime today}) =>
      '${relativeDay(local, today: today)} ${clock(local)}';
}
