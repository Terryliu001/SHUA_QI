/// 阅读偏好（规格 §5.3A、§6.9）。
///
/// **为什么放在 domain 而不是 `ui/reader`**（对规格 §7 的一处有意偏离）：
/// 依赖方向是 `ui → app → domain`，而 `app` 与 `domain` 都要用这套偏好
/// （`session` 记住上次的阅读位置、`export` 需要知道是否走原图）。
/// 若把它放 ui，app/domain 就得反向 import ui，依赖倒置，架构测试会直接拦下来。
///
/// 本文件**不许** import Flutter / dart:ui —— 它必须是纯 Dart。
library;

/// 阅读模式（REQ-02 双模式）。
enum ViewMode {
  /// 一屏一页，自由缩放，左右边缘 15% 滑动翻页。
  paged,

  /// 竖向连排，页间距 8dp，档位缩放，视口 ±1 页常驻。
  scroll,
}

/// 背景纸样式（REQ-15）。
enum PaperStyle {
  /// 零处理，可信基线，也是导出与透明墨迹层的唯一选择。
  original,
  warm,
  ivory,
  gray,
  green,
}

/// `setting` 表中的键名（§5.3A）。键名是稳定契约，改名等于丢用户数据。
abstract final class ReaderSettingKeys {
  static const String defaultMode = 'reader.default_mode';
  static const String defaultPaperStyle = 'reader.default_paper_style';
  static const String defaultIntensity = 'reader.default_intensity';

  /// 单卷覆盖：`reader.view.<workbookId>`，缺失则回落默认值。
  static String viewOf(String workbookId) => 'reader.view.$workbookId';
}

/// 阅读偏好值对象。不可变；所有越界输入在 [fromJson] / [clamp] 里被收敛，不抛异常。
class ReaderPrefs {
  const ReaderPrefs({
    this.mode = ViewMode.paged,
    this.style = PaperStyle.original,
    this.intensity = defaultIntensity,
  });

  /// 从 `setting` 里的 JSON 解析。**任何非法值都回落默认，绝不抛**——
  /// 一个被手改坏的设置项不该让 app 起不来。
  factory ReaderPrefs.fromJson(Map<String, Object?> json) {
    final ReaderPrefs draft = ReaderPrefs(
      mode: _modeByName(json['mode']),
      style: _styleByName(json['style']),
      intensity: _toInt(json['intensity']) ?? defaultIntensity,
    );
    return draft.clamp();
  }

  /// 默认：分页 + 原图 + 强度 55（与 §5.3A 一致）。
  static const int defaultIntensity = 55;

  static const ReaderPrefs defaults = ReaderPrefs();

  final ViewMode mode;
  final PaperStyle style;

  /// 0..100。只影响背景层的不透明度，不影响笔迹。
  final int intensity;

  ReaderPrefs copyWith({ViewMode? mode, PaperStyle? style, int? intensity}) {
    return ReaderPrefs(
      mode: mode ?? this.mode,
      style: style ?? this.style,
      intensity: intensity ?? this.intensity,
    );
  }

  /// 把 intensity 收敛到 0..100。
  ReaderPrefs clamp() {
    if (intensity < 0) {
      return copyWith(intensity: 0);
    }
    if (intensity > 100) {
      return copyWith(intensity: 100);
    }
    return this;
  }

  /// 深色模式与纸感互斥（§6.9.3）：深色下强制退回 `original`，由暗色遮罩统一处理。
  /// 纯函数，不读平台亮度，方便单测。
  ReaderPrefs forSurfaceBrightness({required bool isDark}) {
    if (!isDark || style == PaperStyle.original) {
      return this;
    }
    return copyWith(style: PaperStyle.original);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'mode': mode.name,
    'style': style.name,
    'intensity': intensity,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is ReaderPrefs &&
        other.mode == mode &&
        other.style == style &&
        other.intensity == intensity;
  }

  @override
  int get hashCode => Object.hash(mode, style, intensity);

  @override
  String toString() =>
      'ReaderPrefs(mode: ${mode.name}, style: ${style.name}, intensity: $intensity)';

  static ViewMode _modeByName(Object? raw) {
    for (final ViewMode value in ViewMode.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return ViewMode.paged;
  }

  static PaperStyle _styleByName(Object? raw) {
    for (final PaperStyle value in PaperStyle.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return PaperStyle.original;
  }

  static int? _toInt(Object? raw) {
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.round();
    }
    if (raw is String) {
      return int.tryParse(raw);
    }
    return null;
  }
}
