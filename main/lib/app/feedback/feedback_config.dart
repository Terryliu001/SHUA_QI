import 'package:shuaqi/domain/feedback/feedback.dart';

/// 反馈远端的编译期配置（2026-10-27）。
///
/// 两条通道，二选一：
///
/// 1. **GitHub 私有反馈仓库**（当前默认，用户 2026-10-27 选的口径）
///    ```bash
///    flutter build apk --release --split-per-abi \
///      --dart-define=FEEDBACK_GH_TOKEN=github_pat_xxx
///    ```
///    - owner/repo/branch 有默认值，仓库是**私有**的，手机号只进私有 issue；
///    - token 只该有该仓库的 `Issues: RW` + `Contents: RW`，
///      **不要**用账号的主 token；泄露可随时吊销重发；
///    - token 走 `--dart-define`，**不存在于 git**，只在构建产物里。
///
/// 2. **自建 HTTP 端点**（仓库里 `server/feedback-worker/` 的 Cloudflare Worker）
///    ```bash
///    --dart-define=FEEDBACK_ENDPOINT=https://xxx.workers.dev
///    ```
///    最安全（App 里没有任何 GitHub 凭证），但要有人部署。
///
/// 两者都没配 → 只落本机草稿箱，界面明说"没发出去"，**不假装成功**。
class FeedbackRemoteConfig {
  const FeedbackRemoteConfig({
    this.githubToken = '',
    this.githubOwner = '',
    this.githubRepo = '',
    this.githubBranch = 'main',
    this.endpoint = '',
  });

  factory FeedbackRemoteConfig.fromEnvironment() {
    return FeedbackRemoteConfig(
      githubToken: kFeedbackGhToken.trim(),
      githubOwner: kFeedbackGhOwner.trim(),
      githubRepo: kFeedbackGhRepo.trim(),
      githubBranch: kFeedbackGhBranch.trim().isEmpty
          ? 'main'
          : kFeedbackGhBranch.trim(),
      endpoint: kFeedbackEndpoint.trim(),
    );
  }

  final String githubToken;
  final String githubOwner;
  final String githubRepo;
  final String githubBranch;
  final String endpoint;

  bool get hasGitHub =>
      githubToken.isNotEmpty && githubOwner.isNotEmpty && githubRepo.isNotEmpty;

  bool get hasEndpoint => endpoint.isNotEmpty;

  /// 有没有任何一条能真正把内容送出去的通道。
  bool get enabled => hasGitHub || hasEndpoint;

  /// 给界面看的一句话（不暴露 token / 完整地址）。
  String get channelLabel {
    if (hasGitHub) {
      return 'GitHub 私有仓库';
    }
    if (hasEndpoint) {
      return '自建反馈服务';
    }
    return '未配置';
  }

  /// 仓库界面的链接（只给开发者看的调试信息，界面上可复制）。
  String get repositoryUrl =>
      'https://github.com/$githubOwner/$githubRepo';
}

/// GitHub 反馈通道的编译期注入项。**空 token = 通道未接通**。
const String kFeedbackGhToken = String.fromEnvironment('FEEDBACK_GH_TOKEN');
const String kFeedbackGhOwner = String.fromEnvironment(
  'FEEDBACK_GH_OWNER',
  defaultValue: 'Terryliu001',
);
const String kFeedbackGhRepo = String.fromEnvironment(
  'FEEDBACK_GH_REPO',
  defaultValue: 'SHUA_QI_feedback',
);
const String kFeedbackGhBranch = String.fromEnvironment(
  'FEEDBACK_GH_BRANCH',
  defaultValue: 'main',
);
