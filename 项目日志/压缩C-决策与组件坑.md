# 决策 · 组件坑（压缩自未合卷日志 049–078）

> 提炼自 **未合卷** 日志 049–078。保留"为什么这么做"与"踩过的坑"，供维护 / 移植不要误改、不要重犯。
> 深层渲染红线（墨迹层是 `PaperEffect` 兄弟节点、CameraViewport 无界 `Positioned`、`ColorFilter.matrix` 偏移用 0..255 字节）见 **合卷 006–008**。
> 原文见 `归档/未合卷原文/`。

---

## 一、关键决策（移植者可能误改）

- **跨卷快照无外键**：`favorite` 不设外键 + `source_deleted` 标记，卷删收藏不蒸发；快照目录与 `workbooks/` 平级，孤儿清理不伤。
- **删卷保留**：删前统计收藏数、确认框写"保留 N 道"，删后 `source_deleted=1`；卡片"原卷已删"放**前缀**（长卷名 `ellipsis` 会吃后缀）；看题页回看出处置灰；批量删卷必须 `markSourceDeleted` + 启动 `bootstrap` 自愈补标历史漏标。
- **选择跟随当前视图**：多选跟随视图（全部=题卡 / 按试卷=点文件夹整卷 / 按知识点=当前标签），"全选"只选当前视图。
- **二刷 attempt 模型**：session 前缀 `fav:<id>`，单题与组卷**共享同一份 SIF**；每次重刷独立 `redo/<attemptId>/`；v9 让"同一天多次重刷各记一行"。
- **加题就地确认**（078）：虚线框（`level<=1` 大题容器）上"加题"走 `ConfirmQuestionCorrection`（只 `level 1→2`、`confidence→1`，`key/label/slices` 全保留，JSON `{"t":"confirm"}`，不设 `userAdded`）；实线题仍走 `AddQuestion`。复用 id 依据 `matchExistingQuestionIds` 按 anchor key 复用。**`t:'confirm'` 格式改了必须同步 `RegionCorrection.fromJson`**。叠加层 `_sameMarks` 必须比 `level` / `confidence`（公开 `regionMarksEqual`），否则确认后虚线不立刻变实线。
- **裁剪"被挤压"修复**（073）：`Positioned.fill` + `SizedBox` 紧约束 + `RawImage(fit:BoxFit.fill)` 把图拉成视口比例 → 改 `OverflowBox(0..∞) + ClipRect + contain`，整图可见零变形（实测比例精确 0.75 / 0.45）。**不能被"优化"回 `Positioned.fill` 直包 `SizedBox`**。缩放 / 平移自管 `Listener`（不进手势竞技场），矩阵顺序固定**先平移后缩放**（`M=S·T`）。
- **色系只换强调色**（073）：5 套存 `setting.ui.accent`（存**名字**非序号），只染可点元素 / 选中态 / 主按钮 / 开关 / 导航指示；**不动**灰阶、纸感夜读、判题三态色、切题框色、热力绿。枚举顺序调整不能让用户选择变别的颜色。
- **18 条反馈 4 项口径**（065）：① 云图每层各算一词；② 删 OCR 只删答题卡"识别手写"按钮（后台自动识别保留，`ocr_text` 继续写）；③ 补最小 zip 备份 / 恢复；④ 重刷单独计一次（v8 加 `origin` 维度）。
- **14 表 → 6 表 + Vault JSON**（064 有意识偏离）：量级小、文件可读、迁移只追加；代价是无 SQL 聚合（统计全 Dart 算）。同批另 4 偏离：调度器→手动触发、步骤复述 JSON→对话式、三清单→收藏夹、交卷快照不可变→实时写 `grading.v1.json`。
- **SIF 老数据默认 0/1 兜住不迁移**；**颜色索引只追加不重排**（重排让旧卷笔迹变色，不可逆）；**迁移只追加**不修历史。
- **AI Key 明文迁移成本低**：只改 `LlmConfigStore` 两方法。

---

## 二、组件坑（根因 → 修法，移植 / 升级别重犯）

- **SIF `readPageSize` 大端读取事故**（057）：写入小端、读取用 `getUint16` 默认大端 → 1000×600 读成 413.5×2869.5，笔迹无声拉宽压扁（不抛错，最难发现）。修法 `Endian.little` + 回归 `sif_codec_test`。**跨设备 / 跨语言读 SIF 必带此回归**。
- **公式 `Math` 缓存 Widget 实例导致公式消失**（052）：同公式出现两次，先出现那条空白。修法**不缓存 `Math` 实例**（气泡少，重解析成本低）。
- **关于三入口整块不渲染**（068）：`Row(crossAxisAlignment:stretch)` 放 `Column` 内高度无界 → 子树崩。修法外面包 `IntrinsicHeight` 先把高度定下来。
- **裁剪窗矩阵顺序坑**（068）：新版 `vector_math` 下 `InteractiveViewer` + `Matrix4.translateByDouble` 把已缩放矩阵再乘 → 放弃 `InteractiveViewer`，自管 `_scale/_offset` + `GestureDetector`，矩阵 `M=S·T`。**别再引入 InteractiveViewer**。
- **缓存清理结果看不见**（068）：清完提示显示在列表中间 → 挪到底部固定区（按钮行上方），清完立刻可见。
- **时间线"按试卷"打不开卷**（072）：`groupTimeline` 把分组 key 塞进 `workbookId` → 阅读器找不到卷。修法新增 `groupKey`（只展开 / 去重），`workbookId` 改回真实来源卷 id。**别再把 `groupKey` 当卷 id 传阅读器**。
- **AI 补答案实时写回不跳页**（072）：每得一题 `writeAiAnswers` + 更新 `_liveAiAnswers` + `setState`，整批结束才 `ref.invalidate(regionSetProvider)`。**别改回"每补一题 invalidate"**（会闪 / 跳）。`answers_ai` 合并仍用 `mergeMissing`（PDF / 已有优先）。
- **头像圆形裁切边**（077）：`Container(decoration:border)` 把边框宽加进子节点内边距 → 图被挤成 73×73 方 ∩ 78 圆露直边。修法边框改 `foregroundDecoration`（不参与布局、不产生内边距），图按 78×78 铺满再被圆裁；头像输出也改圆形 alpha。
- **面板拖宽不跟手**（049）：每帧累加再 clamp 丢量 → 改拖动起点记 x，宽度 = `_dragStartPanelWidth + totalGrow`，超界仅暂夹、反向立刻跟手；命中区 16dp → 28dp。
- **书签被 Stack 裁 / 树视图按钮被裁**（050 / 051）：Stack 默认 `hardEdge` 裁书签 → 显式 `clip.none`；`IconButton` 默认 `tapTargetSize:padded` 在 30dp 被裁成残缺 → `MaterialTapTargetSize.shrinkWrap`；`BookmarkClipper` 顶两角 6dp，大图宽 21dp，竖排 ≤4 行用 `runes` 避 emoji 代理对劈开。
- **`onReorder` 废弃**（058）：Flutter 3.41 起用 `onReorderItem`，新回调自己扣偏移，`_reorder` 不再手动 `-1`，否则拖拽排序错位。
- **书架最窄卡片 chip 溢出**（057）：文字外层加 `Flexible`（省略号收缩），父 `Flexible` 给更窄宽时硬顶出。
- **`RecordService` 旁路吞异常 + sqflite insert 陷阱**（062）：写失败绝不影响落笔 / 判题；`insert(ignore)` 冲突返回旧 rowid，**不能据此判"是否新插入"** → 先查后写 + 唯一索引兜并发。
- **`question_order` flush 竞态**（052）：flush 不清零，dispose 又写一次 → flush 写前清目录 + 测试前显式 `await` 清理。
- **导出 PDF `/Length` 与纸张比例坑**（063，详见 B §4）。

---

## 三、071 交接未决（维护者必看）

- **未跑 / 未验证**：最终全量宿主测试（用户交下一位）、20 页高清导出实测（耗时 / 体积 / 峰值内存，超预算再调 2000px）、图形吸附真机视觉（画 10 个含负样本）、裁剪双指缩放（单指已验）、反馈 Worker 端到端（补 URL 后 `--dart-define=FEEDBACK_ENDPOINT`）、演示脚本彩排（`main/demo_assets/DEMO.md` 12 步未彩排）、release 签名 / tag（用户自做）。
- 反馈 Worker `server/feedback-worker/` 未在 Cloudflare 跑过，部署先 `npx wrangler deploy --dry-run`。
- 基线 commit `4d52c43`（295 files, +66746/-2198，294.5MB 验证截图故意不进 git）；交接 commit `f257384`。
- **300 页压力按用户要求没做**，别偷偷补跑后声称已验证。
- 设备当前有测试数据（改过封面、建过一条重刷、导入过测试卷），演示干净状态要先清缓存或重装。
