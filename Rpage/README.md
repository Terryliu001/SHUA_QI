# 刷起 SHUAQI · 展示与下载页

一个**没有任何构建步骤**的静态单页：`index.html` + 一份 CSS + 一份 JS + 几张截图。
直接丢到任意静态服务器（Nginx / GitHub Pages / 对象存储）就能跑。

```
Rpage/
├─ index.html              页面结构 + 全部文案
├─ site.config.js          部署前唯一需要改的文件（APK 地址、GitHub 地址）
├─ favicon.svg             站点图标（与 App 图标同一份 SVG）
├─ apple-touch-icon.png    180px，iOS「添加到主屏」用
├─ icon-512.png            512px 图标大图（og / 商店素材）
├─ assets/
│  ├─ css/site.css         设计令牌 + 全部样式（约 2.9k 行）
│  ├─ js/site.js           滚动动效、三个功能演示、试写画布、热力图、色系
│  └─ img/                 真机截图（1800px 宽，已裁状态栏）+ app-icon.png
└─ download/
   └─ shuaqi-0.1.0.apk     当前内测包（36 MB，release 签名，仅 arm64）
```

---

## 1. 本地预览

```powershell
cd D:\Project_DEV_Management\SHUAQI_project\Rpage
python -m http.server 8788
# 浏览器打开 http://127.0.0.1:8788/
```

> 不要直接双击 `index.html`。用 `file://` 打开时 `site.config.js`、字体与
> 下载链接的行为会和服务器上不一致，至少用上面这条命令起一个本地静态服务。

---

## 2. 上线前要改的三处

### ① APK 地址（`site.config.js`）

```js
window.SHUAQI = {
  apkUrl: "https://github.com/Terryliu001/SHUA_QI/releases/download/v0.1.0/shuaqi-0.1.0.apk",
  github: "https://github.com/Terryliu001/SHUA_QI"
};
```

三种放法，选一个：

| 放法 | 怎么配 | 适合 |
|---|---|---|
| GitHub Releases（**当前默认**） | 建 Release `v0.1.0`，资产名必须是 `shuaqi-0.1.0.apk`，`apkUrl` 已填好 | 推 GitHub，仓库里不放二进制 |
| 跟站点一起 | APK 丢进 `download/`，`apkUrl` 改成 `download/shuaqi-0.1.0.apk` | 自己的服务器，最省事 |
| CDN / 对象存储 | 填完整 URL | 想扛流量、想换包不换网页 |

> 仓库里的 `Rpage/download/` 是 **.gitignore 掉的**，所以走 Pages 时必须用 Release 直链，
> 否则站点的下载按钮会 404。放自己服务器时把包一起上传即可。
>
> `download/shuaqi-0.1.0.apk` 现在是 `app-arm64-v8a-release.apk` 的拷贝：
> **36.6 MB / 38,378,383 字节，release 密钥签名（`D:/keys/shuaqi-release.jks`），只含 arm64**。
> 换包后务必同步页面上的体积、字节数与 SHA-256。

### ② 版本信息（`index.html` → `#download` 区块）

要改的四处，全在一个 `dl` 和一行 `code` 里：

| 位置 | 现在写的 |
|---|---|
| 首屏按钮 | `v0.1.0 · 36.6 MB` |
| 下载区标题旁 | `v0.1.0 · 36.6 MB` |
| 参数表 | `0.1.0 (1)` / `Android 8.0 以上 · arm64` / `36 MB · 38,025,823 字节` / `2026-10-27` |
| `SHA-256` | `467B346C…DB64907A` |

重新算 SHA-256：

```powershell
(Get-FileHash .\download\shuaqi-0.1.0.apk -Algorithm SHA256).Hash
```

### ③ 截图（`assets/img/`）

页面只用了 4 张真机截图，全部是数学卷，**刻意避开了书架截图里那份政治课试卷**：

| 文件 | 用在哪 | 来源 |
|---|---|---|
| `reader-panel.webp` | 首屏设备 | **2026-10-27 真机新拍**：自制高数样卷第 2 页，卷面上手写「你好」+ 荧光笔，右侧题目面板；源图 `_verify/demo/63-hero3.png` |
| `bookshelf.webp` | 00 书架 | **2026-10-27 真机新拍**：8 本卷子（含 5 份自制样卷），源图 `_verify/demo/22-shelf.png` |
| `favorites.webp` | 画廊 1 | `.../2026-10-25-favorites-r4/08-tag-applied.png` |
| `answer-ai.webp` | 画廊 2 | `.../2026-10-25-favorites-r4/12-answer-sheet-ai.png` |
| `redo-paper.webp` | 画廊 3 | `.../2026-10-25-favorites-r4/15-redo-paper3.png` |
| `records.webp` | 记录区 | `.../2026-10-26-bd/12-records.png`（底部空白已裁掉） |

换图时保持 **1800px 宽**、`.webp`（q84）、并同步改 `<img width height>` 两个属性，
否则首屏会抖一下。裁状态栏（顶部 88px）的做法：

```python
from PIL import Image
im = Image.open(src).convert("RGB")
im = im.crop((0, 88, im.width, im.height)).resize((1800, round(im.height * 1800 / im.width)), Image.LANCZOS)
im.save(dst, "WEBP", quality=84, method=6)
```

---

## 3. 部署

### GitHub Pages（本仓库已带 workflow）

`.github/workflows/pages.yml` 会把 **`Rpage/` 目录**直接发成站点根目录，推 main 即触发。

一次性设置：

1. 仓库 → **Settings → Pages → Build and deployment → Source** 选 **GitHub Actions**；
2. 推一次 main（或手动跑一次 `Deploy site (Rpage)` workflow）；
3. 站点地址形如 `https://terryliu001.github.io/SHUA_QI/`（**仓库必须是 public**，私有仓库开 Pages 需要付费计划）。

`site.config.js` 里的 `apkUrl` 已指向 Releases 直链，仓库里不放二进制。

### 自己的服务器（Nginx）

```nginx
server {
  listen 80;
  server_name shuaqi.example.com;
  root /var/www/shuaqi;
  index index.html;

  # webp / 静态资源长缓存；html 不缓存
  location ~* \.(webp|svg|css|js)$ { expires 30d; add_header Cache-Control "public"; }
  location = /index.html { add_header Cache-Control "no-cache"; }

  # APK：大文件，断点续传 + 正确 MIME
  location /download/ {
    add_header Content-Type application/vnd.android.package-archive;
    add_header Accept-Ranges bytes;
    expires 1h;
  }
}
```

HTTPS 一定要开：页面里没有外部请求，也不加载任何 CDN 字体，因此**不存在
Google Fonts 被墙导致中文字体回退**的问题，全部走系统字体栈。

---

## 4. 设计口径（改样式前先看这段）

| 维度 | 取值 | 理由 |
|---|---|---|
| 底色 | `#F4F0E8`（暖纸） | 呼应软件里的"纸感"，比纯白更像卷子 |
| 墨色 | `#15181B` | 不用纯黑，纯黑在纸色上发硬（与 App 的 `ShqPalette.ink` 同源） |
| 强调色 | 默认靛蓝 `#2E5BD8`，另 4 套与 App 的 `ShqAccent` 一一对应 | 导航右上角的 5 个点就是切换器，会存 `localStorage` |
| 深色区块 | `#0B1015` | 比 App 的 `#0E1317` 再深一点，让截图浮起来 |
| 字体 | 系统中文栈（HarmonyOS Sans → MiSans → 苹方 → 微软雅黑） | 零外部依赖，国内加载不会卡 |
| 圆角 | 10 / 16 / 22 / 30 | 与 `ShqRadius` 的节奏一致 |
| 动效 | 200–600ms，`cubic-bezier(.22,1,.36,1)`，只做位移/透明度 | 尊重 `prefers-reduced-motion` |
| 明暗节奏 | 浅 → 浅 → **深（书架）** → 浅（切题）→ **深（判题）** → 浅（二刷）→ 深（记录）→ 浅（归属/问答）→ **深（下载）** | 深色段用来托住截图与三态灯，浅色段留给文字 |

### 4.1 页面顺序

首屏 → 生态位对照 → **00 书架** → 01 切题 → 02 判题 → 03 二刷 → 截图画廊 →
04 试写 → 05 记录 → 06 归属 → 07 问答 → 下载 → 页脚。

> 「00 书架」是 2026-10-27 平板接上后补的一段：原来页面直接从"为什么"跳到"切题"，
> 少了"卷子怎么进来"这一步。截图是当真机实拍的（见 §2③）。

### 4.2 四个"活物"

1. **切题演示**：SVG `rect` 用真实的 DOM 尺寸定位（`getBoundingClientRect`），
   所以改文案、改字号之后框依然贴合；描边用 `pathLength=1 + dashoffset` 做出"画上去"的感觉。
2. **判题演示**：三态灯逐行点亮 + 数字滚动 + 最后浮出"待判 ≠ 错"的说明；
   点「改卷」可重播。
3. **二刷演示**：错题卡 → 组卷 → 空白答题卡（笔迹用 SVG 路径画出来）→ "已保存"提示。
4. **试写画布**：Canvas 2D + Pointer Events，支持手写笔压感、荧光笔、
   **局部橡皮（把一笔切成两段，不是整笔删）**、撤销、清空、6 种纸色。
   这是页面上唯一"真的能玩"的功能，也是产品最容易被误解的那部分——所以放开手让人试。

### 4.3 图标（App 与网站共用）

一张裁了角的卷子、两道手写、一道判题勾，底色是深墨渐变（`#1D2B3A → #080D12`），
勾用品牌靛蓝 `#2E5BD8`。**全部是路径，不依赖字体**，所以 App 与网站可以是同一份 SVG。

| 落点 | 文件 |
|---|---|
| App 启动图标（旧系统） | `main/android/app/src/main/res/mipmap-*/ic_launcher.png`（48/72/96/144/192） |
| App 启动图标（自适应） | `mipmap-anydpi-v26/ic_launcher.xml` + `mipmap-*/ic_launcher_foreground.png` + `values/colors.xml` |
| 网站 favicon / iOS / 大图 | `favicon.svg` / `apple-touch-icon.png` / `icon-512.png` |
| 下载区展示 | `assets/img/app-icon.png`（256px，不透明方版） |

源文件与生成脚本在 `_verify/demo/icon/`（`icon-full.svg` / `icon-fg.svg` / `icon-square.svg`），
改图标就改这三个 SVG，再跑 `make_icon.py` + `make_icon_assets.py`（后者需要本机 Edge 渲染）。
**App 内部左上角那个「刷」徽标没有改**，也不该改——它是应用内的品牌记号，和桌面图标分工不同。

---

## 5. 文案口径（别不小心写过头）

全部文案对齐 `宣传/075-功能清单与宣发建议.md` 的 ✅/⚠️/❌ 口径：

- **没有**交卷总分页 → FAQ 里明说"暂时不能"，下载区单独一栏"这一版还没有"。
- **公式题只给图** → FAQ 里写清，不暗示能识别公式。
- 手写识别**首次需联网下载模型** → 写在 FAQ 第一条。
- 反馈通道**未接通** → 页面不提"反馈"入口，避免误导。
- 不写"提分""押题""AI 一键解题"；不出现任何出版社/学校完整卷面。

页面里出现的数字（49 MB / 51,380,751 字节 / SHA-256 / v0.1.0 / DB v9）都来自
`main/build/app/outputs/flutter-apk/app-release.apk` 的实测值。

---

## 6. 兼容性与自查

- 目标：Chrome / Edge 100+、Safari 15.4+、Firefox 100+、Android Chrome。
- 用到了 `aspect-ratio`、`backdrop-filter`、`mix-blend-mode`、`svh`；
  老浏览器会退化成"没有毛玻璃/没有吸顶"的普通页面，不影响阅读与下载。
- 无 JS 时：所有内容仍在（`[data-reveal]` 默认透明——**这一点要注意**，
  若你改动了脚本，请保留 `prefers-reduced-motion` 分支与 `IntersectionObserver` 兜底）。
- 键盘：全部按钮可 Tab，`:focus-visible` 有 2px 强调色描边；跳过导航链接在最前。
- 移动端 390px 已逐段截图核对（首屏、切题、试写、记录、下载）。
- **真机已验**（OPPO OPD2601，1200×848 逻辑分辨率，系统浏览器）：字体换成 HarmonyOS/OPPO Sans
  后首屏标题仍是两行不换行；`#shelf` 两栏成立；记录页热力图清晰。
  ⚠️ 系统深色模式下浏览器会把整页**强行反色**，已用
  `<meta name="color-scheme" content="only light">` + `html { color-scheme: only light }` 压住，
  改页面时**不要删这两行**。

自查命令（需要本机有 Edge）：

```powershell
# 起服务
python -m http.server 8788
# 截图（自己写的 CDP 小工具，不进交付物）
node ..\_verify\shot.mjs http://127.0.0.1:8788/ ..\_verify\out 1440 900
```

---

## 7. 还没做 / 下一步

- [ ] 你给正式 URL 与 GitHub 仓库地址后，填 `site.config.js`
- [ ] 正式签名包（现在这个 49 MB 包里还带着 x86_64 / v7a 的 ML Kit 库，
      只发 arm64 可以降到约 37 MB，见 `项目日志/074` §1.2）
- [ ] 如果重装"展示版"取了新截图：替换 `assets/img/` 里的图，
      建议用自制样例卷（不要用真实课程卷）。真机上已经放了一套 5 份自制样卷
      （`/sdcard/Download/SHUAQI-demo/`），书架图就是拿它们拍的
- [ ] 可选：`og:image` 换成 1200×630 的社交预览图（现在是阅读器截图，比例偏宽）
- [ ] 可选：接一个不带 Cookie 的访问统计（Plausible / Umami）；
      不接 Google Analytics，和"不上传、不埋点"的调性冲突

---

## 8. 素材与授权

- 截图来自本项目的真机验证（OPPO OPD2601），内容为自制/校内数学卷，页面里已裁掉状态栏。
- 图标是本项目原创路径（`_verify/demo/icon/*.svg`），不含任何第三方图形或字体。
- 字体全部走系统栈，不打包任何字体文件。
- 若把页面公开，请保留页脚"数据只在你的设备上"的表述，不要改成"云端同步"之类。
