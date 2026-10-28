/// App 级 setting 键名（§5.3A 之外的键，键名同样是稳定契约，改名等于丢用户数据）。
///
/// 与 [ReaderSettingKeys]（reader.* 前缀，阅读偏好专用）分开：
/// 一个是"这一卷怎么读"，一个是"这个 app 怎么打扮"。
abstract final class AppSettingKeys {
  /// 主题模式：`system` / `light` / `dark`（对应 Material 的 ThemeMode.name）。
  /// 缺失 = 跟随系统。
  static const String themeMode = 'app.theme_mode';

  /// 上次用的工具：`pen` / `ballpoint` / `highlighter` / `eraser`（对应 InkTool.name）。
  /// 缺失 = 钢笔。只影响**之后**落下的笔，不改已落笔的（T2.2/T2.3）。
  /// 旧版本只存过前三者，读取时未知值一律回落钢笔，不需要数据迁移。
  ///
  /// 2026-10-23 起值格式变为 `tool:color:width;...`（见 `InkBrush.encodeAll`），
  /// 每支笔分别记住颜色与粗细；旧格式会被识别成"只有工具"并回落默认色/粗细。
  static const String inkBrush = 'ink.default_brush';

  /// 题目区域框是否显示（`'1'` / `'0'`）。默认不显示：框会干扰读题与书写。
  static const String regionOverlay = 'reader.region_overlay';

  /// 笔刷工具条形态：`true` = 固定到顶栏下方；其余 = 右下角圆形浮钮（默认）。
  static const String inkToolbarPinned = 'ink.toolbar_pinned';

  /// 右侧面板（题目区域 / 问 AI）宽度，单位 dp 的整数字符串。
  /// 缺失 = 用 [PanelMetrics.defaultFor] 的默认宽度。全局一份，不分卷。
  static const String panelWidth = 'panel.width';

  // ── AI / BYOK（2026-10-24）────────────────────────────────────────────
  //
  // 键名是稳定契约：改了等于丢用户配置。Key 与其他字段分开放，是为了
  // 将来换 flutter_secure_storage 时只迁移 [aiApiKey] 一个键。
  static const String aiBaseUrl = 'llm.base_url';

  /// **敏感**：只存本机 App 私有目录；禁止写日志/导出/上报。
  static const String aiApiKey = 'llm.api_key';

  static const String aiModel = 'llm.model';

  /// `'1'` / `'0'`。默认开：题面图片是权威来源。
  static const String aiAllowImages = 'llm.allow_images';

  /// 秒数的整数字符串，默认 60。
  static const String aiTimeoutSeconds = 'llm.timeout_seconds';

  // ── 收藏夹（2026-10-25）──────────────────────────────────────────────
  //
  /// 上次"知识点归纳行为"的时间（UTC 毫秒，字符串）。任何一次归纳都更新：
  /// AI 归纳、手动编辑知识点、标签条「＋」批量归类、多选「点亮知识点」。
  /// AI 归纳弹窗据此默认勾选"这之后新增、且仍未归纳"的题。
  static const String favoriteLastTagAt = 'favorite.last_tag_at';

  // ── 记录页 / 个人空间（2026-10-25，阶段 9）──────────────────────────────
  //
  /// 历史作答记录是否已回填过（`'1'`）。一次性动作，避免每次启动都扫一遍
  /// 所有卷的 `answer_sheet.v1.json` / `grading.v1.json` / SIF 目录。
  static const String recordsBackfilled = 'records.backfilled';

  /// 个人格言（多行纯文本，≤120 字）。缺失 = 还没写。
  static const String profileMotto = 'profile.motto';

  /// 昵称（≤12 字）。缺失 = 只显示头像与格言。
  static const String profileName = 'profile.name';

  // ── 界面与开发者（2026-10-26）────────────────────────────────────────
  //
  /// **文字模式**：`'1'` = 顶栏与工具栏的图标旁显示功能文字。
  /// 缺失 = 关（既有设计语言是纯图标 + Tooltip）。
  static const String uiIconLabels = 'ui.icon_labels';

  /// 开发者选项是否解锁（版本号连点 8 次）。缺失 = 未解锁。
  static const String devOptionsUnlocked = 'dev.options_unlocked';

  /// 热力图显示的周数（`13` / `26` / `52`）。缺失 = 26。
  static const String recordsHeatWeeks = 'records.heat_weeks';

  /// **色系**（强调色）：`azure` / `celadon` / `iris` / `clay` / `graphite`
  /// （对应 `ShqAccent.name`）。缺失 = 靛蓝（2026-10-24 定稿那套）。
  ///
  /// 与 [themeMode] 分开存：深浅与色系是两件事，用户可能想"深色 + 青瓷"。
  /// 只影响可点元素的颜色，不碰界面灰阶、纸感与判题三态色。
  static const String uiAccent = 'ui.accent';

  // ── 首次启动用户须知（2026-10-28 v0.1.3）──────────────────────────────
  //
  /// 用户是否已确认首次启动的「用户须知」。`'1'` = 已确认，之后不再弹。
  /// 只对**全新安装**弹（`AppDependencies.isFreshInstall`）；老用户升级不打扰。
  static const String noticeAccepted = 'notice.accepted';

  // ── 版本检测与更新（2026-10-28 v0.1.3）────────────────────────────────
  //
  /// 上次检查更新完成的时间（UTC 毫秒字符串）。
  static const String updateLastCheckAt = 'update.last_check_at';

  /// 用户已经看过、不再亮红点的版本号（例如 `0.1.4`）。
  static const String updateSeenVersion = 'update.seen_version';

  /// 最近一次检查到的最新 Release JSON（GitHub Releases 原样裁剪后的字段）。
  static const String updateLatestJson = 'update.latest_json';

  /// 更新前自动备份的文件名/URI/时间（用于更新后展示恢复入口）。
  static const String updateLastBackupName = 'update.last_backup_name';
  static const String updateLastBackupUri = 'update.last_backup_uri';
  static const String updateLastBackupAt = 'update.last_backup_at';

  /// 已经下载好的 APK 版本（用于"下载完成，去安装"）。
  static const String updateDownloadedVersion = 'update.downloaded_version';
}
