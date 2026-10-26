# 刷起 SHUAQI

Android 平板刷题工具：**PDF 背景 + 手写笔迹层 + 自动切题 + 答题卡 + 判题/收藏/记录 + 可选 BYOK AI**。
产品、架构、历史决策在仓库根的 `项目日志/`（先读 `README.md` 与最新的 `070`）。

## 构建

```bash
# 在 main/ 下；依赖版本全部钉死
flutter pub get
flutter build apk --profile
# 产物：build/app/outputs/flutter-apk/app-profile.apk
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

## 用户反馈（可选）

未配置时只存本机并明确提示「通道未接通」。要真正发出去：

1. 按 `server/feedback-worker/README.md` 部署 Cloudflare Worker（写私有 GitHub 仓库 issue）；
2. 构建时注入：
   ```bash
   flutter build apk --profile \
     --dart-define=FEEDBACK_ENDPOINT=https://xxx.workers.dev
   ```
   Worker 配了 `APP_TOKEN` 时再加 `--dart-define=FEEDBACK_APP_TOKEN=...`。

## 已知限制

- 公式只显示原图，不转 LaTeX；交卷结果页/云同步/账号不做。
- 组卷与重刷按每次 attempt 计数；同一天刷两次会算两次。
- 反馈通道需要自备 Worker；300 页压力不做；最终全量测试已交给下一位开发（见 `项目日志/071`）。
- 图形吸附只对钢笔/圆珠笔，判定偏保守；继续移动即可取消。
