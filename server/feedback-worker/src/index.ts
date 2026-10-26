/**
 * 刷起 SHUAQI 用户反馈 Worker（Cloudflare Workers）。
 *
 * 职责：
 * 1. 校验 App 提交的表单（文字 / 手机号 / 最多 3 张图）；
 * 2. 把图片写进**私有** GitHub 仓库的 `feedback/<id>/`；
 * 3. 在同一个私有仓库建 Issue（手机号只在私有 issue 里）；
 * 4. 返回 issue 编号给 App。
 *
 * 为什么用私有仓库：手机号不能出现在公开 issue / 公开图片链接里。
 * 部署见 README。
 */

interface Env {
  GITHUB_TOKEN: string;
  GITHUB_OWNER: string;
  GITHUB_REPO: string;
  GITHUB_BRANCH?: string;
  APP_TOKEN?: string;
}

type FeedbackKind = 'bug' | 'idea' | 'content';

interface IncomingImage {
  name?: string;
  data?: string;
}

interface IncomingFeedback {
  kind?: string;
  text?: string;
  phone?: string;
  app_version?: string;
  device?: string;
  images?: IncomingImage[];
}

const MAX_TEXT = 1000;
const MIN_TEXT = 5;
const MAX_IMAGES = 3;
const MAX_IMAGE_BYTES = 6 * 1024 * 1024;

// 极简限流：每个 isolate 每分钟最多 20 次；Worker 重启后重置，够挡误触。
const recent = new Map<string, number[]>();

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });
}

function fail(message: string, status = 400): Response {
  return json({ ok: false, error: message }, status);
}

function checkRate(ip: string): boolean {
  const now = Date.now();
  const list = (recent.get(ip) ?? []).filter((t) => now - t < 60_000);
  if (list.length >= 20) {
    recent.set(ip, list);
    return false;
  }
  list.push(now);
  recent.set(ip, list);
  return true;
}

function safeText(value: unknown, max: number): string {
  return typeof value === 'string' ? value.trim().slice(0, max) : '';
}

function issueTitle(kind: string, text: string): string {
  const head = text.replace(/\s+/g, ' ').slice(0, 48);
  const label =
    kind === 'idea' ? '建议' : kind === 'content' ? '内容/答案' : '异常';
  return `[反馈·${label}] ${head}`;
}

async function github(
  env: Env,
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  const branch = env.GITHUB_BRANCH || 'main';
  const url = `https://api.github.com${path}`;
  return fetch(url, {
    ...init,
    headers: {
      accept: 'application/vnd.github+json',
      authorization: `Bearer ${env.GITHUB_TOKEN}`,
      'x-github-api-version': '2022-11-28',
      'user-agent': 'shuaqi-feedback-worker',
      ...(init.headers ?? {}),
    },
  });
}

async function putImage(
  env: Env,
  id: string,
  index: number,
  base64: string,
): Promise<string> {
  const path = `feedback/${id}/${index + 1}.png`;
  const branch = env.GITHUB_BRANCH || 'main';
  const response = await github(
    env,
    `/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/contents/${path}`,
    {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        message: `feedback: ${id} image ${index + 1}`,
        content: base64,
        branch,
      }),
    },
  );
  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`图片上传失败：${response.status} ${detail.slice(0, 200)}`);
  }
  return `https://github.com/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/blob/${branch}/${path}`;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== 'POST') {
      return fail('只接受 POST', 405);
    }
    const ip = request.headers.get('cf-connecting-ip') ?? 'unknown';
    if (!checkRate(ip)) {
      return fail('提交太频繁，请过一分钟再试', 429);
    }
    if (env.APP_TOKEN && request.headers.get('x-app-token') !== env.APP_TOKEN) {
      return fail('应用口令不对', 401);
    }
    if (!env.GITHUB_TOKEN || !env.GITHUB_OWNER || !env.GITHUB_REPO) {
      return fail('Worker 还没配置 GitHub 仓库或 token', 500);
    }

    let body: IncomingFeedback;
    try {
      body = (await request.json()) as IncomingFeedback;
    } catch {
      return fail('请求不是合法 JSON');
    }

    const text = safeText(body.text, MAX_TEXT);
    if (text.length < MIN_TEXT) {
      return fail(`正文至少 ${MIN_TEXT} 个字`);
    }
    const kind: FeedbackKind =
      body.kind === 'idea' || body.kind === 'content' ? body.kind : 'bug';
    const phone = safeText(body.phone, 20);
    if (phone && !/^1\d{10}$/.test(phone)) {
      return fail('手机号格式不对');
    }
    const images = Array.isArray(body.images) ? body.images.slice(0, MAX_IMAGES) : [];
    for (const image of images) {
      const data = typeof image.data === 'string' ? image.data : '';
      if (!data) {
        return fail('图片内容为空');
      }
      // base64 近似字节数；超过 6MB 直接拒，避免把 Worker 内存打爆。
      if ((data.length * 3) / 4 > MAX_IMAGE_BYTES) {
        return fail('单张图超过 6MB');
      }
    }

    const id = crypto.randomUUID();
    const links: string[] = [];
    try {
      for (let i = 0; i < images.length; i += 1) {
        links.push(await putImage(env, id, i, images[i].data!));
      }
    } catch (error) {
      return fail(String(error), 502);
    }

    const lines = [
      `**类型**：${kind}`,
      '',
      '**说明**：',
      text,
      '',
      `**App 版本**：${safeText(body.app_version, 40) || '未知'}`,
      `**设备**：${safeText(body.device, 120) || '未知'}`,
      `**手机号**：${phone || '未填写'}`,
      '',
      links.length > 0 ? '**截图**：' : '',
      ...links.map((link, i) => `- [截图 ${i + 1}](${link})`),
      '',
      `<!-- shuaqi-feedback:${id} -->`,
    ];

    const response = await github(
      env,
      `/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/issues`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          title: issueTitle(kind, text),
          body: lines.join('\n'),
        }),
      },
    );
    if (!response.ok) {
      const detail = await response.text();
      return fail(`建 issue 失败：${response.status} ${detail.slice(0, 300)}`, 502);
    }
    const issue = (await response.json()) as { number?: number; html_url?: string };
    return json({
      ok: true,
      issue: issue.number ?? null,
      url: issue.html_url ?? null,
    });
  },
};
