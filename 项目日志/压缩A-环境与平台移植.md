# 环境 · 构建 · 平台移植（压缩自未合卷日志 001–003、065–078）

> 本文件提炼自 **未合卷** 日志：001–003（环境 / 基座 / 书写 spike）与 065–078（收尾 / 反馈批次 / 代码审计 / 宣传页）。
> 深层数据契约（SIF 二进制、切题管线、答题卡 JSON、CameraViewport 渲染红线）见 **合卷 027–043** 与 `README §5.5`；本文件只收"环境复现 + 平台移植"相关的硬事实，避免重复。
> 原文见 `归档/未合卷原文/`。

---

## 1. 工具链版本锁（必须按此还原环境）

| 项 | 版本 |
|---|---|
| Flutter / Dart | 3.47.6 / 3.13.5 |
| AGP / Kotlin / Gradle | 9.1.0 / 2.4.0 / 9.3.1 |
| compileSdk / targetSdk / minSdk | 36 / 36 / 26（字面写进 `build.gradle.kts`，**不读** `flutter.xxxVersion`） |
| JDK | OpenJDK 25.0.4.1 LTS（Microsoft），`JAVA_HOME=E:\MC_JDK\jdk-25.0.4.1+1` |
| 本机路径 | Flutter `E:\FlutterSDK\flutter`；SDK `ANDROID_SDK_ROOT=E:\AndroidStudio\AndriodVirtualDevice`（注意 **Anriod 少一个 i，不得更正**）；NDK `28.2.13676358` |

- **风险**：JDK 25 与 Gradle/AGP 兼容性**未验证**（class file major 69）。构建报错再考虑回退 JDK 21，**不要预防性更换**。
- minSdk 26 → 设备 SQLite 3.19 **不支持 `ON CONFLICT DO UPDATE`**（要 3.24+），见 B §1。

---

## 2. 环境三件套坑（换机器 / CI 必看）

1. **NDK 28.2.13676358 必装**：AGP 9.1 在**配置阶段**就解析默认 `ndkVersion`；旧 `sdkmanager` 壳会把 `ndk;28.2...` 拆错包名导致自动安装失败。正确做法：`android sdk install "ndk/28.2.13676358"`。
2. **Gradle 走腾讯镜像**：`gradle-wrapper.properties` 的 `distributionUrl=https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip`。Java 的 `URLConnection` **不读** `http_proxy` 环境变量，所以代理救不了 Gradle 下载。
3. **`flutter test` 必须清代理**（`env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY flutter test`），但 `build` / `pub get` **必须保留代理**——同一环境两者要求相反，脚本化极易写反。
4. **pdfium 原生资产从 GitHub 拉**，本机不通会**静默卡 15 分钟无输出**。构建前必跑 `tool/patch_pdfium_mirror.py`（前缀换成 `gh-proxy`，幂等）。
5. **`sdkmanager` 已废弃**，用新 CLI：`android sdk install <pkg>/<version>`、`android sdk list --all`。
6. **`abiFilters` 对 Flutter 自己的库无效**（Flutter 用 `-Ptarget-platform` 覆盖）；release 只出 arm64 靠 `--target-platform android-arm64`。

---

## 3. 构建 / 测试 / 发布脚本

- `tool/run_tests.sh`（及 `.ps1` PowerShell 版，因本机无 bash 且 Git Bash 在沙箱里信号管道被拒）：**临时摘掉 `pdfrx` → `flutter test` → 恢复 `pubspec.yaml`**。宿主测试必须走它（否则 pdfrx native assets 在沙箱编译不过）。
  - **3 个既存失败永远存在**（与功能无关，任何全量测试都要用脚本摘 pdfrx）：`answer_ink_store_test` / `ink_edit_test` / `page_layer_test`。
  - **事故预案**：脚本被强杀会让 `pubspec.yaml` 停在"pdfrx 被注释" + 留 `.pubspec.yaml.host-test-backup`。恢复：确认依赖区有 `pdfrx: 2.9.0` → `git checkout HEAD -- main/pubspec.lock` → `flutter pub get` → 删 `.pubspec.yaml.host-test-backup`。
- `tool/build_release.ps1`：自动注入反馈 token（来自 `_verify/.gh_app_token`，脚本不打印）、输出体积 / SHA。release **不要再手敲** `flutter build`。
- `tool/patch_pdfium_mirror.py`：构建前跑。

---

## 4. R8 / ProGuard（profile 通过 ≠ release 通过）

- **事故**：release 包因 R8 把 ML Kit 反射构造器 `DigitalInkRecognitionRegistrar.<init>` 裁掉 → 启动 `NoSuchMethodException` 闪退（profile 不跑 R8 所以没暴露）。
- **修法**：`android/app/proguard-rules.pro` keep `com.google.mlkit.**`、`com.google.android.gms.internal.mlkit_*`、实现 `ComponentRegistrar` 的类及其 `<init>()`、`androidx.startup.**`、`androidx.work.**`；release 显式 `isMinifyEnabled = true` + `proguardFiles(...)`。
- **每个版本至少装一次 release 冒烟**。

---

## 5. APK 体积

- release arm64 ≈ **36.7MB（38,509,535 B）**。构成：`libflutter 11.2MB` / `libapp 10.1MB` / `libdigitalink 6.57MB`(arm64) / `libpdfium 6.09MB`。
- **白给 12.6MB**：ML Kit 的 `libdigitalink.so` 仍按 `x86_64(8.37MB)` + `armeabi-v7a(4.26MB)` 全打（AAR JNI 不受 `--target-platform` 影响）。`--split-per-abi` 发 `app-arm64-v8a-release.apk` 即可省 ~25%。
- `--obfuscate --split-debug-info=build/symbols` 可再省 0.5–1MB，**符号表必须留存**否则崩溃栈不可读。
- Dart 死代码不进包（AOT tree-shaking），体积只对 native 库 / ABI / 字体 / 资源敏感，拆 Dart 文件不为体积只为可维护性。

---

## 6. 平台绑定点（上 iOS / 桌面 / Web 必须改）

| 绑定点 | 当前实现 | 移植要做的 |
|---|---|---|
| 手写 OCR | `google_mlkit_digital_ink_recognition 0.16.1`（Android JNI，首次使用联网下模型） | 换跨平台 OCR；`recognizeImage`(引擎 B) 仍是空实现 |
| 存图 / 存 PDF | `MethodChannel('com.shuaqi.shuaqi/media')` → Android `MediaStore`（`Pictures/SHUAQI` / `Download/SHUAQI`） | iOS Photos / 桌面文件系统 / Web Blob 锚点下载 |
| AI 客户端 | `infra/ai/openai_client.dart` 用 `dart:io HttpClient`（SSE 按行读） | **Web 无 `dart:io`**，必须换 `package:http` 流式或 `dart:html` |
| 联网权限 | `AndroidManifest` `INTERNET` + `usesCleartextTraffic=true` | iOS `NSAppTransportSecurity` 例外；Web 默认禁明文 |
| 原生重启 | 备份恢复后 `restartApp`（`FLAG_ACTIVITY_CLEAR_TASK|NEW_TASK`） | 各平台等价通道 |
| 设备信息 | `MainActivity.deviceInfo` MethodChannel | 各平台重写 |
| PDF 渲染 | `pdfrx`（native assets，宿主测试需摘除以过沙箱） | 非 Android 需替代或处理 native assets |
| 多文件选择 | `file_picker 13` 取 `paths`（**不是** `singleOrNull`） | 各平台 `paths` 语义差异（已踩过只取第一份） |
| 调试取文件 | `adb exec-out run-as pkg cat` | Android 专属，移植后换调试方式 |

---

## 7. 真机设备特性与 adb 限制

- OPPO **OPD2601** / Android 16 / API 36 / arm64 / 2120×3000@400dpi → **dpr 2.5**，横屏逻辑 1200×848dp；冷启动 332–457ms；压感 0.0–0.877，采样率中位 187–240Hz。必须 `-s` 指定设备。
- adb 常掉授权：`adb kill-server && adb start-server` 再弹允许框。
- **双指捏合 / 笔尾橡皮（`invertedStylus`）无法用 `input` / `sendevent` 注入** → 这些手势路径只能真笔复验，无自动化回归（移植新设备时是高风险区）。

---

## 8. 反馈通道

- **方案 A（现行）**：GitHub 私有仓库 `Terryliu001/SHUA_QI_feedback` + 专用 token，经 `--dart-define=FEEDBACK_GH_TOKEN=...` 编进 APK（token 来自 `_verify/.gh_app_token`，不进 git、脚本不打印）。
- **老 `FEEDBACK_ENDPOINT`**（Cloudflare Worker，`server/feedback-worker/`）通道保留但优先级低。
- 链路：`FeedbackOutbox.submit()` 先落盘 `vault/feedback/<id>.json` + `<id>-<n>.img` → `GitHubFeedbackGateway` `PUT` 图片 + `POST` issue；仅 2xx 算 `delivered`；422 = 已存在（幂等）；失败落 `failed` 可重试；启动一帧后 + 回前台自动补发（5 分钟节流）。
- 设备信息通道只回 **厂商+型号 / Android 版本 / API 级别**，不取 IMEI / 序列号 / 广告 id / 账号。
- **换 token 流程**：新 token → 替换 `_verify/.gh_app_token` → 重新构建发布（别把主 token 编进去）。
- 遗留：token 可提取（方案 A 已知代价）；无回复通知；>6MB 大图未压缩。

---

## 9. Rpage 静态宣传站（`Rpage/`，零构建）

- 无 npm / 无打包 / 无外部字体；部署前**唯一要改** `site.config.js` 的 `apkUrl` / `github`。
- **真机浏览器翻车**：系统深色模式下国内浏览器无视浅色声明强行反色（米色变深棕）→ 必须保留 `html { color-scheme: only light }` + meta（`README §6` 标注不要删这两行）。
- 下载区 **版本号 / 体积 / SHA-256 三处必须与 APK 同步**（改 APK 必修网页，否则网页在撒谎）。

---

## 10. 版本与发版

- 当前 `0.1.3+4`（versionCode 2004），`AppInfo.version` 唯一定义点。release arm64 `38,641,451 B`，SHA `385612637B2F85F17BE5AF6424577F82FE860B992854F6213124A890247905A0`（0.1.3）。
- 宿主测试 **689 passed / 3 failed**（3 个永远 pdfrx 既存失败）。
- 发版三处同步：站点、Release 正文、APK 本身（体积 / SHA / 版本）。
- 0.1.3 更新检查/下载/安装是**自研轻量实现**（`infra/update` + `app/update` + Kotlin `installApk`），不是 `flutter_autoupdate`；替换实现时 UI/红点状态机不用动。安装需 `REQUEST_INSTALL_PACKAGES` + `FileProvider`，并校验包名/versionCode/签名。

