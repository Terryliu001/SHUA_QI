/// 笔迹「页键」里 session 字符串的编解码（纯 Dart）。
///
/// 为什么在 domain：session id 是**数据契约**——SIF 的落盘路径、`ink_providers`
/// 的存储路由、作答记录归属，三处都靠它区分"这是 PDF 页笔迹 / 答题卡某题的笔迹 /
/// 收藏重刷的笔迹"。把它留在 state 层会让 domain 与测试都够不到。
library;

/// 答题卡手写画布的 session 编码：`ans:<draftSessionId>:<questionId>`。
const String kAnswerInkPrefix = 'ans';

/// 收藏二刷画布的 session 编码：`fav:<favoriteId>`（旧版，单份笔迹）。
/// 2026-10-26 起每次重刷独立：`fav:<favoriteId>@<attemptId>`。
const String kFavoriteRedoPrefix = 'fav';

String answerInkSessionId(String draftSessionId, String questionId) =>
    '$kAnswerInkPrefix:$draftSessionId:$questionId';

({String sessionId, String questionId})? parseAnswerInkSession(String raw) {
  final List<String> parts = raw.split(':');
  if (parts.length != 3 || parts[0] != kAnswerInkPrefix) {
    return null;
  }
  if (parts[1].isEmpty || parts[2].isEmpty) {
    return null;
  }
  return (sessionId: parts[1], questionId: parts[2]);
}

String favoriteRedoSessionId(String favoriteId, [String? attemptId]) {
  final String id = (attemptId ?? '').trim();
  return id.isEmpty
      ? '$kFavoriteRedoPrefix:$favoriteId'
      : '$kFavoriteRedoPrefix:$favoriteId@$id';
}

/// 解析二刷 session（含 attempt）。不是二刷返回 null。
///
/// 格式：
/// - 旧版：`fav:<favoriteId>` → attemptId = null；
/// - 新版：`fav:<favoriteId>@<attemptId>`。
({String favoriteId, String? attemptId})? parseFavoriteRedoSessionRef(
  String raw,
) {
  if (!raw.startsWith('$kFavoriteRedoPrefix:')) {
    return null;
  }
  final String id = raw.substring(kFavoriteRedoPrefix.length + 1);
  if (id.isEmpty) {
    return null;
  }
  final int at = id.indexOf('@');
  if (at < 0) {
    return (favoriteId: id, attemptId: null);
  }
  final String favoriteId = id.substring(0, at);
  final String attemptId = id.substring(at + 1);
  if (favoriteId.isEmpty || attemptId.isEmpty) {
    return null;
  }
  return (favoriteId: favoriteId, attemptId: attemptId);
}

/// 旧调用点的兼容入口：只要收藏 id。
String? parseFavoriteRedoSession(String raw) =>
    parseFavoriteRedoSessionRef(raw)?.favoriteId;
