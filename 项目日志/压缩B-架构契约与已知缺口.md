# 架构契约 · 已知缺口（压缩自未合卷日志 049–078）

> 提炼自 **未合卷** 日志 049–078。深层契约（SIF 二进制布局、切题管线、答题卡 JSON 字段、CameraViewport 渲染红线）见 **合卷 027–043** 与 `README §5.5`；本文件补其"未覆盖 / 更精确"的部分 + 收尾检查结论 + 性能基线。
> 原文见 `归档/未合卷原文/`。

---

## 1. DB 演进（迁移只在 `infra/db/migrations.dart`，**只追加**；v9 当前）

- **v5 `llm_usage`**：`id, at INTEGER, model, task(chat/solve/grade/test), tokens_in/out INTEGER, estimated(1=字符粗估，UI 标 ≈), ok, INDEX(at)`。
- **v6 收藏三表**：`favorite(id, question_id, workbook_id, workbook_title, label, page_index, kind, stem_text, rect, knowledge_tags≤5×≤20字, verdict, source_deleted, created_at, updated_at)`；`favorite_set(id, ...)`；`favorite_set_item(set_id FK→favorite_set.id ON DELETE CASCADE, favorite_id FK→favorite.id ON DELETE CASCADE, sort, PK(set_id,favorite_id))`。
  - ⚠️ **注意 `favorite_set_item` 有级联外键**（`README`/`MEMORY` 旧说"都无外键"已过时），删组卷会连带删成员。
- **v7 `answer_log`**：`id, at, day(本地 yyyy-MM-dd), workbook_id, workbook_title, question_id, label, kind, page_index, source, verdict, hits`，`UNIQUE(question_id, day)`，**无外键**。4 处打点：`InkEditController._scheduleSave`(source=ink)、`GradingController.onGraded`(source=grade，6 调用点收敛为 1)、`fav:` 重刷回表(source=redo)。
- **v8** 加 `origin(workbook/set/redo)` / `origin_title`，唯一索引变 `(question_id, day, origin)`（同卷重刷当天可多一行）。
- **v9** 加 `attempt_id` / `favorite_id`，唯一索引 `(question_id, day, origin, attempt_id)`（同一天多次重刷各一行）。
- 回填 `record_backfill.dart` 口径版本 `kBackfillVersion='2'`，只认 `answer_sheet.updated_at` / SIF mtime / `grading.verdict!=none` 的 at；**批量改卷写下的 `none` 不计入**（否则一天多出几十题）。
- 适配层 `domain/records/answer_log.dart`：`answerQuestionIdOf` / `answerRecordKeyOf` 放 domain（脱离 pdfrx 才能单测）。
- ⚠️ SQLite 3.19（Android 8 / minSdk 26）不支持 `ON CONFLICT DO UPDATE`（要 3.24+）→ **永远别写 upsert**。

---

## 2. 收藏快照目录（`vault/favorites/<id>/`）

- `stem.png`（收藏时 2.8×pt、上限 1800×2600；打开时 PNG 头宽 **<1400 原地重渲染覆盖**，原子写）；
- `answer.png`（可空）、`chat.json`（可空）、`grading.json`（可空）、`answer.json`（可空）；
- `ink/pN.sif` + `.bak`（页尺寸 1000×600，session 前缀 `fav:<id>`，**单题与组卷共享同一份**）；
- `paper.json`（`AnswerPaper`）；
- `redo/<attemptId>/`（meta + paper + ink）。
- 孤儿清理只扫 `workbooks/`，不伤 `favorites/`。

---

## 3. 备份 / 恢复 / 缓存（`066` / `068` / `074`）

- 备份 zip = `shuaqi.db` + 整个 `vault/` + `manifest.json`（`{version, dbVersion, at, workbooks, favorites, records}`）；**备份前 `PRAGMA wal_checkpoint(TRUNCATE)`**（SQLite 3.19 无 `VACUUM INTO`）。落 `Download/SHUAQI/SHUAQI_backup_...zip`。
- 恢复：留底（当前数据挪 `support/restore_stash/<时间>/`）→ 校验 manifest → 覆盖 → **原生 `restartApp`** → 提示"已恢复"。坏包（缺中央目录）被 manifest 闸门挡掉。
- 缓存 10 类（`domain/app/cache_report.dart`）：**可清** = `thumb/` / `layout/answer_crops/` / `*.tmp` / `.bak`（`.bak` 不删，磁盘损坏唯一退路）；**不可清** = `source.pdf` / `sessions/` / `favorites/` / `profile/` / 反馈草稿 / 数据库。
- 074 建议：SQLite 开 `journal_mode=WAL` + `synchronous=NORMAL`（连带备份 / 恢复要处理 `-wal`/`-shm`）；PageImageCache 320MB 上限无内存压力响应（加 `didHaveMemoryPressure`）。⚠️ 开 WAL 后重测"设置回滚"bug（切色后重启变回 azure，R3）。

---

## 4. 导出 PDF（`063` / `070`）

- `domain/export/export_options.dart`：三开关（原题 / 笔迹 / 答题卡）+ 四预设（纯试卷 / 试卷+笔迹 / 完整存档 / 只要答题卡）；**关原题即连带关笔迹**。
- `app/export/pdf_writer.dart`：纯 Dart，`/FlateDecode` + `/Predictor 15 /Colors 3 /Columns w`，中文标题 UTF-16BE 十六进制；导出宽 **1700px**，高清 **2400px**（≈290dpi）。
- 坑：① `/Length` 与 stream 字节必须严格一致（latin1 摊字节，图片流全 ≥128）；② 纸张比例必须读该题 `AnswerPaper.widthPt/heightPt`，用默认 1000×600 会把 A4 竖纸压扁；③ 落点 toast 判断必须 `toLowerCase().contains('download')`。
- PDF 导出整份拼内存（`BytesBuilder`），20 页 2400px ~40–60MB 峰值，超预算再改逐对象 `IOSink`。

---

## 5. AI 契约（`052` / `053` / `058` / `060`）

- `infra/ai/openai_client.dart` 用 `dart:io` SSE；错误分类 `notConfigured/auth/rateLimited/network/server/timeout/badResponse/unsupportedImage`。
- `layout/ai_chat.v1.json`：每题最多 **60 轮**；助手轮可带 `thinking` + `deep_thinking`（≤6000 字），有 reasoning 默认展开；错误轮不落盘。
- 深度思考开关只对 DeepSeek 发 `thinking:{type:enabled/disabled}` + `reasoning_effort:high`，400 且提这两字段自动去掉重试，`max_tokens=4096`。
- 流式 usage：请求带 `stream_options.include_usage`，末尾 `choices:[] + usage` 也解析。
- `layout/answers_ai.v1.json` 与 `answers.v1.json` 合并**只补缺**（PDF / 已有优先）。
- 知识归纳 `domain/ai/knowledge_tag.dart`：提示词短键 `q1..qN`（防模型抄错 ULID）；容错 4 种 JSON 形状；每批 **20 题**、`max_tokens` **2048**；只改仍无标签的题；失败不写半份；结果必须经用户**逐题确认**才写库。
- AI Key 明文存 `setting.llm.api_key`；换 `flutter_secure_storage` 只改 `LlmConfigStore` 两方法，调用方不动（低成本）。
- ⚠️ 真实厂商端点**从未联调**（一直假 SSE）；相册附图不持久化；AI 判题不随笔迹 / rev 变化自动失效。

---

## 6. 判题契约（`043` / `064`）

- `layout/grading.v1.json`：`AnswerVerdict{none,correct,wrong,pending}` + `GradeSource{auto,manual}`；一键改卷 `applyAuto` 只在 `existing==null || !existing.manual` 时覆盖（**永不覆盖 manual/ai**）。
- 客观题 `judgeObjective`：全角→半角、`×→x`、`÷→/`、去 `答案:/答:/解:`、去尾标点；`looksSubjective` 长度>20 或含 证明/略/同上/见图 → null 落 pending；数值容差 `1e-6*max(1,|ref|)`。
- OCR 三字段 `ocr_text` / `ocr_conf` / `ocr_engine('ink_mlkit')`；置信 `1/(1+exp(score))` clamp(0.05,0.99)，ML Kit 原始分越负越好；`ocrStale` 标待重识别（无就地纠偏 UI）；`trustedOcrConfidence=0.65`（`grading_policy.dart`）。**`RegionGrade` 是切题置信度不是判题**。

---

## 7. 切题重放与编辑（`032` / `043`，深度见合卷）

- `regions.v1.json` 只读，`kCutterVersion=5`；打开卷发现 `cutter!=5` → 后台静默重切，覆盖层按 anchor 重放。
- `corrections.json` 是 **10 种 op**（move/resize/addSlice/removeSlice/add/delete/merge/split/rename/lock），解析器必须全支持；**重算必须在落盘之后、不能防抖**（否则文件写了重算读到空覆盖层 → 数据不同步）。
- `anchorKey = page<0 ? '$label|none|0' : '$label|$page|${y.round()}'`；匹配 精确 → 同页 y 差 ≤80pt 取最近 → 都锚不上留文件不删。`question.id` 跨重算稳定（`id_keep` 一个旧 id 只被认领一次）。
- **灰虚线 = `level==1` 大题容器**（不是紫色作答框 `isAnswer=true` 画的紫色虚线）。

---

## 8. 偏好 / 选项（全走 `setting`）

- 阅读偏好 `reader.default_*`（只有全局一份）；面板宽度 `panel.width`（题目与 AI 面板共用，拖动用**绝对位移**）；
- 文字模式 `ui.icon_labels`；开发者选项 `dev.options_unlocked`（版本号连点 **8 次**解锁）；
- 热力范围 `records.heat_weeks`（13/26/52，默认 26）；
- 色系 `ui.accent`（存**名字**非序号，默认 `azure #1F6FEB`）；`restore_pending`。

---

## 9. 064 收尾检查：10 项关键遗漏（优先级）

1. **公式识别（P0）**：`formula_engine.dart` 只有接口，`assets/models/` 空，无 ONNX 依赖 → 公式行只裁图不出 LaTeX。
2. **交卷 / 结果页**：`SessionDao.markSubmitted` 无 UI 调用，无 result_page → 二刷（T7.1）不可达。
3. **笔迹归属引擎**：无 `domain/assignment/`，页内手写不归题。
4. **图像 OCR 引擎 B + 调度器**：只有 `mlkit_ink_engine`（引擎 A），无 `app/ocr/ocr_scheduler`；无 GMS 设备无兜底。
5. **导出 / 备份家族只做 1/6**：透明墨迹 PDF / 笔迹 JSON / 练习记录 md / 公式清单 / zip 备份恢复（已补）/ 存储归档 多缺。
6. **识别结果修订链**：`ocr_text` 单值，无 `text_block` 多版本 / `edited_by_user` / diff → 手改会被下次识别覆盖。
7. **release 签名 / tag**：只有 debug 签名；git tag 空。
8. **双机兼容**：仅 OPPO OPD2601 一台。
9. **安装 / 备份 / 帮助文档**：`main/README` 仅 645 字；无脱敏日志导出。
10. **AI Key 明文**（见 §5）。

---

## 10. 已知边界与性能基线（064 / 074）

- **12 边界**：✅ 跨页题、SIF `.bak` 双兜底、API 5 种降级；◐ 框重叠（压线归小框有，斜纹提示未做）、OCR 超时（有 try 无按钮）、>300 页（50 页实测）；✗ **磁盘满**（无写入前空间探测）、**斜纹提示**完全缺。
- **性能**：冷启动 332–457ms；50 页首屏 28ms；翻页中位 3ms；书写最差帧 5.0ms；单页 SIF 5000 笔 34.7KB；20 页导出外推 ~5MB。未测：视觉延迟、峰值内存（设计 320MB 位图上限）、20 页真实体积。
- **074 热点 P1**：面板拖动整页每帧重建（`reader_page.dart:3736` 在 `build()` 内 `ref.watch(panelWidthProvider)`，`ReaderPage` 4446 行全重建）→ 只把"面板 + 阅读区右侧留白"包进 `Consumer`；3 处 `Image.file` 无 `cacheWidth`（`favorite_card.dart:241` 等，卡片墙 ~30MB 位图）。
- **P2**：收藏分组 `build` 重算（`favorites_page.dart:290/311`）；12 个 family 中 3 个无 autoDispose（`inkEditProvider` / `workbookThumbnailProvider` / `answerSheetControllerProvider`）。
- **"不要动"清单**：`page_image_cache.dart` 按字节 LRU + 单飞；`page_layer.dart` 的 `RepaintBoundary` 分层；SIF 编解码走 `Isolate.run`；`RegionOverlay` 内部 `RepaintBoundary`；`sha1OfFile` 流式哈希；Vault `.tmp+rename` 原子写；backup 用 `ZipFileEncoder` 流式；record_providers 统计放 `FutureProvider`（不在 build 里算）。

---

## 11. v0.1.3 增量（2026-10-28）

- **判题快照（JSON 增量，不升 DB）**：
  - `AnswerSheetEntry` 加 `ink_sig`：作答框 + 答题卡各页 `revision/笔画/点数/包围盒` + 卷面框内笔迹的指纹。展开答题情况时与当前指纹比对，不同即自动重 OCR。
  - `QuestionGrade` 加 `judged_text / judged_sig / judged_ref_hash`：判题时用的 OCR、作答指纹、参考答案哈希。旧记录缺字段按“无快照”保守保留 AI 原判。
  - 明显改动阈值 `kSignificantAnswerSimilarity=0.80`（`domain/region/answer_freshness.dart`），纯函数可单测。
- **新增 setting 键**：`notice.accepted`；`update.last_check_at / seen_version / latest_json / last_backup_name / last_backup_uri / last_backup_at / downloaded_version`。
- **更新链路**：`infra/update/github_release_client.dart`（无 token，公开仓库）+ `app/update/update_service.dart`（流式下载/SHA-256/取消）+ Kotlin `installApk`（`REQUEST_INSTALL_PACKAGES` + `FileProvider` + 包名/versionCode/签名校验）。支持 `--dart-define=UPDATE_API_BASE` 本地假源。
- **备份体系**：`app/backup/backup_library.dart` + `infra/platform/media_store_channel.dart`（list/rename/delete/import/openUrl）；`BackupService.createBackup({name})`。MediaStore 只暴露本应用当前安装创建的 Downloads 条目，卸载重装后旧备份走文件选择。
- **验证基线**：689 passed / 3 个 pdfrx 既存失败；release `38,641,451 B` / SHA `38561263…247905A0`。

