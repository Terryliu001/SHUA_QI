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
│  ├─ app.dart                        ShuaqiApp（全项目唯一 MaterialApp）+ themeModeProvider
│  ├─ router.dart                     路由表（Navigator 1.0，不引 go_router）
│  ├─ errors/error_handling.dart      三层错误兜底 + CrashFallback
│  ├─ theme/tokens.dart               设计令牌（间距/圆角/动效/字阶/语义色/纸色）
│  ├─ theme/app_theme.dart            主题唯一构造点
│  ├─ bookshelf/bookshelf_page.dart   书架（T1.4 落地，现为路由落点）
│  ├─ reader/reader_page.dart         阅读器（T1.5 落地，现验证"深色退回原图"规则）
│  └─ widgets/math/math_view.dart     公式渲染契约（T6.7 落地）
├─ state/
│  └─ app_providers.dart              跨页面共享状态（readerPrefsProvider）
├─ domain/
│  ├─ ink/ink_doc.dart                InkPoint / InkRect / InkStroke / InkDoc
│  ├─ ink/ink_store.dart              InkStore 契约
│  └─ reader/reader_prefs.dart        ViewMode / PaperStyle / ReaderPrefs / setting 键名
└─ infra/
   ├─ pdf/pdf_source.dart             PdfSource 契约 + TextRun
   ├─ pdf/paper_renderer.dart         PaperRenderer 契约
   ├─ ocr/ocr_engine.dart             OcrEngine 契约 + OcrOutput / OcrLine
   ├─ formula/formula_engine.dart     FormulaEngine 契约 + FormulaResult
   └─ ai/llm_client.dart              LlmClient 契约 + 请求/响应类型
```

尚未建立的层目录（`app/` 下的 session / ocr / region / grade / analysis / export，
`domain/` 下的 geometry / assignment / grading / formula / markup / latex，
`infra/` 下的 db / vault / export，`ui/` 下的 panel / settings）
**在对应任务块开工时创建**，不要提前建空壳——空目录不会提醒你"这里还没实现"。

---

## 三条写代码时的硬规矩

1. **不在 `build()` 里做 IO / JSON / 网络 / DB**；不在 `onPointerMove` 链上 `await` / `setState`。
2. widget 里不写字面量颜色与字号，从 `ui/theme/tokens.dart` 取。
3. 新增依赖前先看 `pubspec.yaml` 顶部的白名单；新增即违规。
