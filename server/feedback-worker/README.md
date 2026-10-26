# 用户反馈 Worker（Cloudflare Workers）

App 的「设置 → 关于 → 用户反馈」在配置了远端端点后走这里：

```
App ──POST JSON──▶ Worker ──GitHub API──▶ 私有仓库 issue + 截图
```

## 为什么是私有仓库

反馈里可选填手机号（修复后短信/电话回复）。公开仓库的 issue 与图片链接任何人都能看，
**不要**把手机号发到公开仓库。请新建/使用一个**私有**仓库专门收反馈。

## 部署

1. 建一个私有 GitHub 仓库，例如 `shuaqi-feedback-private`（空仓库即可）。
2. 建 fine-grained PAT：
   - Repository access：只选这个私有仓库；
   - Permissions：`Issues: Read and write`、`Contents: Read and write`。
3. 安装 Wrangler（本机已有 Node 时）：
   ```bash
   npx wrangler login
   cd server/feedback-worker
   ```
4. 改 `wrangler.toml` 里的 `GITHUB_OWNER` / `GITHUB_REPO` / `GITHUB_BRANCH`。
5. 写 token（不要写进 toml / 仓库）：
   ```bash
   npx wrangler secret put GITHUB_TOKEN
   ```
6. 可选应用口令（防止别人扫到 Worker 地址乱提）：
   ```bash
   npx wrangler secret put APP_TOKEN
   ```
7. 部署：
   ```bash
   npx wrangler deploy
   ```
   记下输出的 `https://shuaqi-feedback.<account>.workers.dev`。

## 让 App 用上

构建时注入端点（URL 不要写死在源码里）：

```bash
flutter build apk --profile \
  --dart-define=FEEDBACK_ENDPOINT=https://shuaqi-feedback.xxx.workers.dev
```

如果 Worker 配了 `APP_TOKEN`，再加：

```bash
--dart-define=FEEDBACK_APP_TOKEN=同一个口令
```

没配 `FEEDBACK_ENDPOINT` 时，App 仍走本机草稿并明确提示「通道未接通」。

## 接口

`POST /`

```json
{
  "kind": "bug",
  "text": "第 3 页的题目框拖不动",
  "phone": "13800138000",
  "app_version": "0.1.0",
  "device": "OPPO OPD2601",
  "images": [{ "name": "1.png", "data": "<base64>" }]
}
```

成功：

```json
{ "ok": true, "issue": 12, "url": "https://github.com/..." }
```

失败：`{ "ok": false, "error": "..." }`，HTTP 4xx/5xx。

## 注意

- 手机号只进私有 issue；Worker 不写日志、不回传 token。
- 截图写进私有仓库 `feedback/<uuid>/`，issue 里放 GitHub 链接；删除 issue 后图片仍会留在仓库，需要时手动清理。
- 限流是单 isolate 内存级的（每分钟 20 次），不是严格风控；需要更强风控再加 Turnstile/数据库。
