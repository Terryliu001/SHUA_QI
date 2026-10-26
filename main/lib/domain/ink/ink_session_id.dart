/// 笔迹「页键」里 session 字符串的编解码（纯 Dart）。
///
/// 为什么在 domain：session id 是**数据契约**——SIF 的落盘路径、`ink_providers`
/// 的存储路由、作答记录归属，三处都靠它区分"这是 PDF 页笔迹 / 答题卡某题的笔迹 /
/// 收藏重刷的笔迹"。把它留在 state 层会让 domain 与测试都够不到。
library;

/// 答题卡手写画布的 session 编码：`ans:<draftSessionId>:<questionId>`。
const String kAnswerInkPrefix = 'ans';

/// 收藏二刷画布的 session 编码：`fav:<favoriteId>`。
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

String favoriteRedoSessionId(String favoriteId) =>
    '$kFavoriteRedoPrefix:$favoriteId';

/// 解析二刷 session：不是二刷返回 null。
///
/// 收藏 id 是 ULID（不含冒号），所以按「前缀 + 剩余整段」判断，
/// 不会和 `ans:` 的 3 段格式混淆。
String? parseFavoriteRedoSession(String raw) {
  if (!raw.startsWith('$kFavoriteRedoPrefix:')) {
    return null;
  }
  final String id = raw.substring(kFavoriteRedoPrefix.length + 1);
  return id.isEmpty ? null : id;
}
