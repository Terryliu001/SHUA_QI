import 'dart:async';

import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';

/// 「问 AI」对话历史的落盘。
///
/// 为什么放 Vault 的 `layout/ai_chat.v1.json` 而不是新开一张 DB 表：
/// 1. 对话天然按卷/按题归属，和 `answers.v1.json`/`grading.v1.json` 同层；
/// 2. 重切题、删卷的现有清理路径已经覆盖 `layout/`；
/// 3. 这一轮不改数据库版本，减少迁移风险。
///
/// 写入串行化：同一卷的两道题可能同时完成回复，读-改-写不能互相覆盖。
class AiChatStore {
  AiChatStore(this._store);

  final LayoutStore _store;
  Future<void> _queue = Future<void>.value();

  Future<List<ChatTurn>> load(String workbookId, String questionId) async {
    final Map<String, Object?>? json = await _store.readAiChat(workbookId);
    return _turnsOf(json, questionId);
  }

  /// 写一题的完整历史；只保留可落盘的消息（错误气泡不写）。
  Future<void> save(
    String workbookId,
    String questionId,
    List<ChatTurn> turns,
  ) {
    final Future<void> task = _queue.then((_) async {
      final Map<String, Object?>? existing = await _store.readAiChat(
        workbookId,
      );
      final Map<String, Object?> chats = <String, Object?>{
        if (existing?['chats'] is Map)
          ...(existing!['chats'] as Map).cast<String, Object?>(),
      };
      chats[questionId] = ChatTurn.listToJson(turns);
      await _store.writeAiChat(workbookId, <String, Object?>{
        'version': 1,
        'chats': chats,
      });
    });
    _queue = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  static List<ChatTurn> _turnsOf(
    Map<String, Object?>? json,
    String questionId,
  ) {
    final Object? chats = json?['chats'];
    if (chats is! Map) {
      return const <ChatTurn>[];
    }
    return ChatTurn.listFromJson(chats[questionId]);
  }
}
