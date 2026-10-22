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
///
/// **纸样式 = 卷面的配色，不是 App 主题。** 二者正交（2026-10-22 用户拍板）：
/// App 主题只管骨架（书架 / AppBar / 浮层）的明暗，卷面永远按这里选的来。
/// 所以「深色 App + 原图纸」是正常的白底黑字，「浅色 App + 夜读纸」也是合法的
/// 黑底白字 —— 不要再用 `Theme.of(context).brightness` 去改卷面配色。
enum PaperStyle {
  /// 零处理，可信基线，也是导出与透明墨迹层的唯一选择（白底黑字）。
  original,
  warm,
  ivory,
  gray,
  green,

  /// 夜读：duotone 翻转亮度轴（暖黑纸 + 暖白墨）。
  ///
  /// 这是**一种纸样式**，不是"深色模式的必然结果"：夜读下印刷内容退化为双色暖调，
  /// 换来的是一天里任何时段都能读下去的对比度（详见 [NightTint]）。
  night,
}

/// 纸样式到"纸是暗的还是亮的"的唯一判定。
///
/// 决定三件事：滤镜走 duotone 还是乘法、笔迹墨色取暖白还是深墨、
/// 页面投影用暗底还是亮底那一套。只允许在 domain 判定，UI 不许自己写 `==`。
extension PaperStyleTone on PaperStyle {
  /// true = 暗纸亮墨（夜读）。
  bool get isDarkPaper => this == PaperStyle.night;
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

  /// 旧版"深色下纸感强制退回 original"的规则已废止（2026-10-22）。
  ///
  /// 原来的耦合会带来两个错：深色 App 下一卷试卷被强行涂成夜读（用户要的
  /// 是"黑底白字作为一个风格选项"，不是"主题一黑 PDF 就黑"），
  /// 而且浅色 App 里根本选不到夜读。现在纸样式与主题完全正交，
  /// 由 [PaperStyle] 自身决定卷面配色。

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
