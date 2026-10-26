import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';

void main() {
  group('ReaderPrefs', () {
    // 2026-10-24 第二轮（用户第 6 条）：默认改成滚动 + 手势模式。
    // 设计理念："任何一次启动文件，默认打开时都是滚动模式 + 手势操控"，
    // 而且不再按卷记忆（偏好只有全局一份）。
    test('默认值：滚动 / 原图 / 强度 55 / 手势模式', () {
      const ReaderPrefs prefs = ReaderPrefs.defaults;
      expect(prefs.mode, ViewMode.scroll);
      expect(prefs.style, PaperStyle.original);
      expect(prefs.intensity, 55);
      expect(prefs.handTool, isTrue);
    });

    test('旧数据没有 hand 字段时按新默认（手势开）', () {
      final ReaderPrefs restored = ReaderPrefs.fromJson(<String, Object?>{
        'mode': 'paged',
        'style': 'warm',
        'intensity': 40,
      });
      expect(restored.mode, ViewMode.paged);
      expect(restored.handTool, isTrue);
      // 明确写了 false 才关掉。
      expect(
        ReaderPrefs.fromJson(<String, Object?>{'hand': false}).handTool,
        isFalse,
      );
    });

    test('JSON 往返不丢字段', () {
      const ReaderPrefs source = ReaderPrefs(
        mode: ViewMode.scroll,
        style: PaperStyle.warm,
        intensity: 30,
        handTool: true,
      );
      final ReaderPrefs restored = ReaderPrefs.fromJson(source.toJson());
      expect(restored, source);
    });

    test('非法设置回落默认，不抛异常', () {
      final ReaderPrefs restored = ReaderPrefs.fromJson(<String, Object?>{
        'mode': 'tree',
        'style': 42,
        'intensity': 'abc',
      });
      expect(restored.mode, ViewMode.scroll);
      expect(restored.style, PaperStyle.original);
      expect(restored.intensity, 55);
    });

    test('强度越界被收敛到 0..100', () {
      expect(const ReaderPrefs(intensity: -20).clamp().intensity, 0);
      expect(const ReaderPrefs(intensity: 400).clamp().intensity, 100);
      expect(
        ReaderPrefs.fromJson(<String, Object?>{'intensity': 400}).intensity,
        100,
      );
      expect(
        ReaderPrefs.fromJson(<String, Object?>{'intensity': -1}).intensity,
        0,
      );
    });

    test('纸样式与 App 主题正交：夜读只是一种纸样式，能存取、可往返', () {
      // 深色 App 主题不再改卷面配色 —— 原图纸（白底黑字）就是原图纸。
      const ReaderPrefs original = ReaderPrefs(style: PaperStyle.original);
      expect(original.toJson()['style'], 'original');

      // 夜读可被选中、能落盘、能读回（浅色界面下也合法）。
      const ReaderPrefs night = ReaderPrefs(style: PaperStyle.night);
      final ReaderPrefs restored = ReaderPrefs.fromJson(night.toJson());
      expect(restored.style, PaperStyle.night);
      expect(restored.style.isDarkPaper, isTrue);
      expect(original.style.isDarkPaper, isFalse);
    });

    test('暗纸判定只认夜读（决定墨色与投影的那把钥匙）', () {
      for (final PaperStyle style in PaperStyle.values) {
        expect(style.isDarkPaper, style == PaperStyle.night);
      }
    });

    test('setting 键名是稳定契约', () {
      expect(ReaderSettingKeys.defaultMode, 'reader.default_mode');
      expect(ReaderSettingKeys.defaultPaperStyle, 'reader.default_paper_style');
      expect(ReaderSettingKeys.defaultIntensity, 'reader.default_intensity');
      expect(ReaderSettingKeys.defaultHand, 'reader.default_hand');
      expect(ReaderSettingKeys.viewOf('wb_abc'), 'reader.view.wb_abc');
    });
  });
}
