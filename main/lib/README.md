# lib/ 分层与约定

依赖方向（规格 §4.1，由 `test/architecture_test.dart` 强制执行）：

```text
ui ──→ state ──→ domain
 │                 ↑
 └──→ app ──→ infra ┘
```

- `domain` **纯 Dart**：不许 import Flutter / `dart:io` / `dart:ui`。几何、归属、判题、公式判别、LaTeX 后处理全部在这层，必须能脱离 Flutter 单测。
- `infra` **可以有 dio/dart:ui/插件**，但不许持有 Widget（不许 import material/widgets）。
- `app` 用例编排：不许持有 Widget，不许 import material/widgets。
- `ui` / `state` / `main.dart` 是唯一允许 import material 的地方。

---

## 当前结构（只列已存在的文件；空目录用到时再建）

```text
lib/
├─ main.dart                          入口：ensureInitialized → 装错误兜底 → ProviderScope
├─ ui/
│  ├─ app.dart                        ShuaqiApp（全项目唯一 MaterialApp）
│  ├─ router.dart                     路由表（Navigator 1.0，不引 go_router）：外壳 + 阅读器
│  ├─ shell/app_shell.dart            应用外壳：自适应导航（宽屏 rail / 窄屏 bar）+ 四 tab 保活
│  ├─ errors/error_handling.dart      三层错误兜底 + CrashFallback
│  ├─ theme/tokens.dart               设计令牌（间距/圆角/动效/字阶/语义色/纸色/夜读/暗色阶梯）
│  ├─ theme/app_theme.dart            主题唯一构造点（浅色 seed 派生 / 暗色手调冷灰阶梯）
│  ├─ theme/theme_mode_codec.dart     主题模式 ↔ setting 字符串（纯函数）
│  ├─ bookshelf/bookshelf_page.dart   书架主页：导入/搜索/长按菜单/下拉刷新/损坏态
│  ├─ bookshelf/workbook_menu_sheet.dart  长按菜单 + 重命名/删除对话框
│  ├─ records/records_page.dart       记录 tab（占位，T7.1）
│  ├─ mistakes/mistakes_page.dart     错题本 tab（占位，T7.2）
│  ├─ settings/settings_page.dart     设置：主题/阅读默认（真实）+ AI/存储（置灰说明）
│  ├─ reader/reader_page.dart         阅读器（T1.5 落地）
│  ├─ reader/page_image_cache.dart    页位图缓存（独立 clone 交付契约，见 030）
│  ├─ reader/page_layer.dart          单页图层 + 取图失败可重试态
│  ├─ reader/scroll_view.dart         连续滚动（相机矩阵 / 预热 / 轴向锁定）
│  ├─ reader/paged_view.dart          分页 + 页码胶囊
│  ├─ reader/thumb_drawer.dart        缩略图抽屉（当前页描边 + 页码）
│  ├─ widgets/empty_state.dart        共享空态组件（动作图标可传参）
│  ├─ widgets/soft_icon.dart          软底图标公共件
│  ├─ widgets/feature_preview_page.dart 诚实的路线图预览页（记录/错题）
│  ├─ widgets/paper_effect.dart       纸感/夜读合成（只作用背景层）
│  └─ widgets/math/math_view.dart     公式渲染契约（T6.7 落地）
├─ state/
│  ├─ app_providers.dart              跨页面共享状态（依赖装配、书架、文件健康探测）
│  ├─ reader_prefs_providers.dart     阅读偏好读写（readerPrefsProvider + defaults）
│  └─ theme_mode_provider.dart        主题模式（Notifier + setting 持久化）
├─ domain/
│  ├─ ink/ink_doc.dart                InkPoint / InkRect / InkStroke / InkDoc
│  ├─ ink/ink_store.dart              InkStore 契约 + InkLoadIssue
│  ├─ ink/sif_codec.dart              SIF v1 编解码（zlib / CRC / 量化）
│  ├─ app/setting_keys.dart           App 级 setting 键名（app.theme_mode）
│  ├─ model/workbook.dart             Workbook 值对象
│  ├─ model/workbook_search.dart      书架标题搜索过滤（纯函数）
│  ├─ reader/reader_prefs.dart        ViewMode / PaperStyle / ReaderPrefs / setting 键名
│  ├─ reader/paper_tint.dart          纸感乘法增益（纯函数）
│  ├─ reader/night_tint.dart          夜读 duotone 矩阵（纯函数）
│  └─ reader/scroll_math.dart         滚动画布纯几何（可见集/主可见页/夹紧）
└─ infra/
   ├─ ink/sif_ink_store.dart          SIF InkStore（原子写/.bak/isolate）
   ├─ ink/ink_writer.dart             500ms 防抖落盘调度
   ├─ db/dao/ink_state_dao.dart       ink_state（revision/字节数/路径）
   ├─ pdf/pdf_source.dart             PdfSource 契约 + PageBitmapSource（屏显位图）+ TextRun
   ├─ pdf/paper_renderer.dart         PaperRenderer 契约
   ├─ ocr/ocr_engine.dart             OcrEngine 契约 + OcrOutput / OcrLine
   ├─ formula/formula_engine.dart     FormulaEngine 契约 + FormulaResult
   └─ ai/llm_client.dart              LlmClient 契约 + 请求/响应类型
```

尚未建立的层目录（`app/` 下的 session / ocr / region / grade / analysis / export，
`domain/` 下的 geometry / assignment / grading / formula / markup / latex，
`infra/` 下的 db / vault / export，`ui/` 下的 panel）
**在对应任务块开工时创建**，不要提前建空壳——空目录不会提醒你"这里还没实现"。

---

## 三条写代码时的硬规矩

1. **不在 `build()` 里做 IO / JSON / 网络 / DB**；不在 `onPointerMove` 链上 `await` / `setState`。
2. widget 里不写字面量颜色与字号，从 `ui/theme/tokens.dart` 取。
3. 新增依赖前先看 `pubspec.yaml` 顶部的白名单；新增即违规。
