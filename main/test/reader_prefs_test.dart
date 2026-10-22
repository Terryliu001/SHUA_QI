import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';

void main() {
  group('ReaderPrefs', () {
    test('默认值符合 §5.3A：分页 / 原图 / 强度 55', () {
      const ReaderPrefs prefs = ReaderPrefs.defaults;
      expect(prefs.mode, ViewMode.paged);
      expect(prefs.style, PaperStyle.original);
      expect(prefs.intensity, 55);
    });

    test('JSON 往返不丢字段', () {
      const ReaderPrefs source = ReaderPrefs(
        mode: ViewMode.scroll,
        style: PaperStyle.warm,
        intensity: 30,
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
      expect(restored.mode, ViewMode.paged);
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

    test('深色下纸感强制退回 original（§6.9.3）', () {
      const ReaderPrefs warm = ReaderPrefs(style: PaperStyle.warm);
      expect(warm.forSurfaceBrightness(isDark: true).style, PaperStyle.original);
      // 浅色下不动
      expect(warm.forSurfaceBrightness(isDark: false).style, PaperStyle.warm);
      // 本来就是 original 时保持原对象语义
      expect(
        const ReaderPrefs().forSurfaceBrightness(isDark: true).style,
        PaperStyle.original,
      );
    });

    test('setting 键名是稳定契约', () {
      expect(ReaderSettingKeys.defaultMode, 'reader.default_mode');
      expect(ReaderSettingKeys.defaultPaperStyle, 'reader.default_paper_style');
      expect(ReaderSettingKeys.defaultIntensity, 'reader.default_intensity');
      expect(ReaderSettingKeys.viewOf('wb_abc'), 'reader.view.wb_abc');
    });
  });
}
