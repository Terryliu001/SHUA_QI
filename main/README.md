# 刷起 SHUAQI

Android 平板刷题工具：**PDF 背景 + 手写笔迹层 + 自动切题 + 答题卡 + 判题/收藏/记录 + 可选 BYOK AI**。
产品、架构、历史决策在仓库根的 `项目日志/`（先读它的 `README.md` 与最新的 `077`）。

## 构建

```bash
# 在 main/ 下；依赖版本全部钉死
flutter pub get

# 日常调试
flutter build apk --profile
# 产物：build/app/outputs/flutter-apk/app-profile.apk

# 发布包（只发 arm64；反馈 token 从 _verify/.gh_app_token 读，不进 git）
powershell -File tool/build_release.ps1
# 产物：build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

> **pdfrx / pdfium**：首次构建或换机后如卡在 native assets，先跑
> `python tool/patch_pdfium_mirror.py`（pdfium 从 GitHub 下载，本机可能不通）。
> 发布签名 / tag 由维护者自行处理，本仓库不保存 keystore。

## 测试

宿主机没有 bash 时用 PowerShell 版运行器：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool/run_tests.ps1
# 或单个文件
powershell ... -File tool/run_tests.ps1 test/export_options_test.dart
```

它会临时摘掉 pdfrx（native assets 在宿主机上会挂）→ `flutter test` → 恢复 `pubspec.yaml`。
`test/bookshelf_grid_layout_test.dart` 需要 sqflite，只在真机/集成测试跑；
`answer_ink_store_test` / `ink_edit_test` / `page_layer_test` 是 pdfrx import 链的既存宿主失败。

## 数据与备份

- 所有用户数据在应用私有目录的 Vault + `shuaqi.db`；卸载即删。
- 设置 → 数据：缓存统计与清除（只清缩略图 / 作答原图裁切 / `.tmp`）、导出 zip 备份、从备份恢复（恢复前留底并重启）。
- 导出 PDF 落系统「下载/SHUAQI」；题目截图落相册「Pictures/SHUAQI」。

## AI（BYOK）

设置 → AI 分析填任意 OpenAI 兼容端点、Key、模型。DeepSeek 示例：

- 端点 `https://api.deepseek.com`
- `deepseek-flash`：**支持图像理解**，判手写选它
- `deepseek-v4-pro`：不支持图像，只适合有文字层的题

Key 只存本机；批量判题逐题串行并显示进度；AI 结论标「AI · 请自检」，手改优先。
配置指导在 AI 配置标题旁的 info 按钮里。

## 用户反馈（已接通）

反馈走**开发者的 GitHub 私有反馈仓库**（`Terryliu001/SHUA_QI_feedback`）：文字 + 最多 3 张截图，
截图落到私有仓库 `feedback/<id>/`，issue 里只出现私有链接；手机号选填、只进私有 issue。

构建时注入一个只对该仓库有 `Issues` + `Contents` 写权限的 fine-grained token：

```bash
flutter build apk --release --split-per-abi \
  --dart-define=FEEDBACK_GH_TOKEN=github_pat_xxx
```

`tool/build_release.ps1` 会自动从 `_verify/.gh_app_token`（gitignore）读 token，避免写进命令行历史。
**不要**用账号主 token；泄露只需在 GitHub 吊销重发，影响范围仅限这个私有仓库。

没有 token 时构建出的包只落本机草稿箱（界面明说"没发出去"），不会假装成功。
也仍支持自建 Worker：`--dart-define=FEEDBACK_ENDPOINT=https://xxx.workers.dev`（见 `server/feedback-worker/`）。

行为：**先落盘再发送**；失败进「待发送 / 发送失败」，可在「我提过的反馈」里重试/删除，
回到前台或下次启动会自动补发。

## 已知限制

- 公式只显示原图，不转 LaTeX；交卷结果页/云同步/账号不做。
- 组卷与重刷按每次 attempt 计数；同一天刷两次会算两次。
- 反馈没有回复通知（开发者回复后不会在 App 内推送）；300 页压力不做。
- 图形吸附只对钢笔/圆珠笔，判定偏保守；继续移动即可取消。
