import 'dart:convert';
import 'dart:typed_data';

import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/favorite_set_plan.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/region/answer.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:shuaqi/infra/db/app_database.dart';
import 'package:shuaqi/infra/db/dao/favorite_dao.dart';
import 'package:shuaqi/infra/db/dao/question_dao.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 收藏夹的核心用例：把一道题「收藏」成**跨卷的独立快照**。
///
/// 从 2026-10-25 起，收藏不再是指向卷内 id 的引用（旧 `layout/favorites.v1.json`），
/// 而是：写一条 `favorite` 表记录 + 把题面图/作答图/对话/判题/答案复制到
/// `favorites/<id>/`。原卷删除后，表记录与快照文件都还在，看题照常。
///
/// 分工：
/// - 本类只管「编排 + 落盘」，**不碰 PDF / 不渲染图片**（那是 reader 侧的事）；
/// - 图片字节、JSON 都由调用方（reader）在收藏那一刻准备好，通过 [FavoriteCapture] 传入；
/// - 这样 store 保持在 app/infra 层，不会顺 import 链把 pdfrx 拖进可测范围。
class FavoriteStore {
  FavoriteStore({
    required this.db,
    required this.vault,
    required this.layout,
  });

  final AppDatabase db;
  final Vault vault;
  final LayoutStore layout;

  FavoriteDao get _dao => FavoriteDao(db.raw);

  /// 收藏一道题。写表 + 写快照文件（原子），失败则清掉已写文件再抛。
  Future<Favorite> capture(FavoriteCapture capture) async {
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final String id = Ulid.next();

    await _writeSnapshot(id, capture);

    final Favorite favorite = Favorite(
      id: id,
      questionId: capture.questionId,
      workbookId: capture.workbookId,
      workbookTitle: capture.workbookTitle,
      label: capture.label,
      ordinal: capture.ordinal,
      kind: capture.kind,
      stemText: capture.stemText,
      pageIndex: capture.pageIndex,
      rect: capture.rect,
      knowledgeTags: capture.knowledgeTags,
      verdict: capture.verdict,
      sourceDeleted: false,
      createdAt: now,
      updatedAt: now,
    );
    try {
      await _dao.insert(favorite);
    } on Object {
      await vault.deleteFavoriteDir(id);
      rethrow;
    }
    return favorite;
  }

  Future<void> _writeSnapshot(String id, FavoriteCapture capture) async {
    try {
      if (capture.stemPng != null) {
        await vault.writeAtomically(VaultPaths.favoriteStem(id), capture.stemPng!);
      }
      if (capture.answerPng != null) {
        await vault.writeAtomically(
          VaultPaths.favoriteAnswerImg(id),
          capture.answerPng!,
        );
      }
      if (capture.chatJson != null) {
        await vault.writeAtomically(
          VaultPaths.favoriteChat(id),
          utf8.encode(jsonEncode(capture.chatJson)),
        );
      }
      if (capture.gradingJson != null) {
        await vault.writeAtomically(
          VaultPaths.favoriteGrading(id),
          utf8.encode(jsonEncode(capture.gradingJson)),
        );
      }
      if (capture.answerJson != null) {
        await vault.writeAtomically(
          VaultPaths.favoriteAnswer(id),
          utf8.encode(jsonEncode(capture.answerJson)),
        );
      }
    } on Object {
      await vault.deleteFavoriteDir(id);
      rethrow;
    }
  }

  /// 取消收藏：删表行 + 删快照目录。
  Future<void> remove(String favoriteId) async {
    await _dao.delete(favoriteId);
    await vault.deleteFavoriteDir(favoriteId);
  }

  /// 改知识点标签（收藏夹长按菜单「编辑知识点」用）。
  Future<void> updateKnowledgeTags(String favoriteId, List<String> tags) async {
    await _dao.updateTags(
      favoriteId,
      tags,
      at: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  /// 给一批收藏追加一个知识点标签（标签条「＋新建」的批量归类用）。
  ///
  /// 已含该标签的跳过；逐条读改写（收藏量是几十级，不做批量 SQL）。
  Future<void> appendKnowledgeTag(
    Iterable<String> favoriteIds,
    String tag,
  ) async {
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final String id in favoriteIds) {
      final Favorite? favorite = await _dao.byId(id);
      if (favorite == null) {
        continue;
      }
      final List<String> tags = <String>[...favorite.knowledgeTags];
      if (tags.contains(tag)) {
        continue;
      }
      tags.add(tag);
      await _dao.updateTags(id, tags, at: now);
    }
  }

  /// 某源题是否已收藏。返回收藏 id（没收藏为 null），供 toggle 用。
  Future<String?> idOfQuestion(String questionId) =>
      _dao.idByQuestionId(questionId);

  /// 某卷有多少收藏（删卷前的「会保留 N 题」提示用）。
  Future<int> countOfWorkbook(String workbookId) =>
      _dao.countByWorkbook(workbookId);

  /// 卷被删后标记来源已删：看题页据此走快照兜底、卡片显示「原卷已删」。
  Future<void> markSourceDeleted(String workbookId) => _dao.markSourceDeleted(
    workbookId,
    at: DateTime.now().toUtc().millisecondsSinceEpoch,
  );

  Future<Favorite?> byId(String favoriteId) => _dao.byId(favoriteId);

  /// 全部收藏，按最近更新倒序。
  Future<List<Favorite>> list() => _dao.listByUpdatedAt();

  /// 某卷的收藏（按试卷卡片点开后的列表页用）。
  Future<List<Favorite>> listOfWorkbook(String workbookId) =>
      _dao.listByWorkbook(workbookId);

  /// 卷改名后同步收藏快照上的卷名（与书架**双向**：书架改名也调这里）。
  ///
  /// 卷已删（快照兜底）时也能调：只更新快照里的卷名，不影响 `source_deleted`。
  Future<int> renameWorkbook(String workbookId, String title) {
    return _dao.updateWorkbookTitle(
      workbookId,
      title,
      at: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  /// 删除某一卷的全部收藏（快照目录一并删）。返回删掉的条数。
  Future<int> removeOfWorkbook(String workbookId) async {
    final List<Favorite> items = await _dao.listByWorkbook(workbookId);
    for (final Favorite favorite in items) {
      await remove(favorite.id);
    }
    return items.length;
  }

  // ---- 知识点归纳时间（AI 归纳弹窗的默认勾选口径） ----

  /// 上次任何"归纳行为"的时间（UTC 毫秒）；0 = 从没归纳过。
  Future<int> loadLastTagAt() async {
    try {
      final String? raw = await SettingDao(
        db.raw,
      ).get(AppSettingKeys.favoriteLastTagAt);
      return int.tryParse(raw ?? '') ?? 0;
    } on Object {
      return 0;
    }
  }

  Future<void> touchLastTagAt() async {
    try {
      await SettingDao(db.raw).put(
        AppSettingKeys.favoriteLastTagAt,
        '${DateTime.now().toUtc().millisecondsSinceEpoch}',
      );
    } on Object {
      // 写不进去只影响下次默认勾选，不影响本次归纳。
    }
  }

  // ---- 组卷（T8.4）：命名题集，只活在收藏夹 ----

  /// 全部组卷（带成员数），按最近更新倒序。
  Future<List<FavoriteSet>> listSets() => _dao.listSets();

  Future<FavoriteSet?> setById(String setId) => _dao.setById(setId);

  /// 新建组卷，可选一次带上成员（`favoriteIds` 顺序即卷内题序）。
  Future<FavoriteSet> createSet({
    required String name,
    Iterable<String> favoriteIds = const <String>[],
  }) async {
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final String id = Ulid.next();
    final String clean = name.trim().isEmpty ? '未命名题集' : name.trim();
    await _dao.insertSet(
      FavoriteSet(id: id, name: clean, createdAt: now, updatedAt: now),
    );
    final int added = await _appendItems(id, favoriteIds);
    return FavoriteSet(
      id: id,
      name: clean,
      createdAt: now,
      updatedAt: now,
      itemCount: added,
    );
  }

  /// 把一批收藏加入组卷，返回**真正新增**的条数（已是成员的不重复加）。
  Future<int> addToSet(String setId, Iterable<String> favoriteIds) async {
    final List<String> existing = await _dao.setItemIds(setId);
    final List<String> next = planSetAppend(
      existing: existing,
      incoming: favoriteIds,
    );
    final int added = next.length - existing.length;
    if (added == 0) {
      return 0;
    }
    await _appendItems(setId, next.skip(existing.length));
    return added;
  }

  /// 从组卷移除一条（连刷时"这题不刷了"用）。
  Future<void> removeFromSet(String setId, String favoriteId) async {
    final int at = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _dao.removeSetItem(setId, favoriteId);
    await _dao.touchSet(setId, at: at);
  }

  /// 拖动排序：按给定的完整顺序重写 sort（长按拖动调整题目顺序）。
  Future<void> reorderSet(
    String setId,
    List<String> orderedFavoriteIds,
  ) async {
    for (int i = 0; i < orderedFavoriteIds.length; i++) {
      await _dao.updateSetItemSort(setId, orderedFavoriteIds[i], i);
    }
    await _dao.touchSet(
      setId,
      at: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  Future<void> renameSet(String setId, String name) async {
    final String clean = name.trim();
    if (clean.isEmpty) {
      return;
    }
    await _dao.renameSet(
      setId,
      clean,
      at: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  Future<void> deleteSet(String setId) => _dao.deleteSet(setId);

  /// 组卷成员（收藏对象，顺序 = 卷内题序）。
  ///
  /// 已取消收藏的成员会因外键级联从 `favorite_set_item` 消失，
  /// 所以这里查不到就是真的没了，不做"空壳补位"。
  Future<List<Favorite>> itemsOfSet(String setId) async {
    final List<String> ids = await _dao.setItemIds(setId);
    if (ids.isEmpty) {
      return const <Favorite>[];
    }
    final Map<String, Favorite> byId = <String, Favorite>{
      for (final Favorite favorite in await _dao.byIds(ids))
        favorite.id: favorite,
    };
    return <Favorite>[
      for (final String id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// 一条收藏属于哪些组卷。
  Future<List<String>> setIdsOf(String favoriteId) =>
      _dao.setIdsOf(favoriteId);

  /// 追加成员：从当前最大 sort 往后排，保证卷内题序稳定。
  Future<int> _appendItems(String setId, Iterable<String> favoriteIds) async {
    int sort = await _dao.nextSetSort(setId);
    int added = 0;
    for (final String favoriteId in favoriteIds) {
      if (favoriteId.isEmpty) {
        continue;
      }
      await _dao.addSetItem(setId, favoriteId, sort++);
      added++;
    }
    if (added > 0) {
      await _dao.touchSet(
        setId,
        at: DateTime.now().toUtc().millisecondsSinceEpoch,
      );
    }
    return added;
  }

  // ---- 快照读取（看题页用）----

  /// AI 对话历史快照（无则空）。
  Future<List<ChatTurn>> loadChat(String favoriteId) async {
    final Object? raw = await _readJson(VaultPaths.favoriteChat(favoriteId));
    if (raw is! Map) {
      return const <ChatTurn>[];
    }
    return ChatTurn.listFromJson(raw['turns']);
  }

  /// 写回 AI 对话快照。
  Future<void> saveChat(String favoriteId, List<ChatTurn> turns) async {
    await vault.writeAtomically(
      VaultPaths.favoriteChat(favoriteId),
      utf8.encode(jsonEncode(<String, Object?>{
        'turns': ChatTurn.listToJson(turns),
      })),
    );
  }

  /// 判题结论快照（无则 null）。
  Future<QuestionGrade?> loadGrading(String favoriteId) async {
    final Object? raw = await _readJson(VaultPaths.favoriteGrading(favoriteId));
    if (raw is! Map) {
      return null;
    }
    return QuestionGrade.fromJson(raw.cast<String, Object?>());
  }

  /// 写回判题快照 + 列表上的判定点（T8.3b：问 AI 面板里「判我的作答」）。
  Future<void> saveGrading(String favoriteId, QuestionGrade grade) async {
    await vault.writeAtomically(
      VaultPaths.favoriteGrading(favoriteId),
      utf8.encode(jsonEncode(grade.toJson())),
    );
    await _dao.updateVerdict(
      favoriteId,
      grade.verdict,
      at: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  /// 参考答案快照（无则 null）。
  Future<AnswerNote?> loadAnswerNote(String favoriteId) async {
    final Object? raw = await _readJson(VaultPaths.favoriteAnswer(favoriteId));
    if (raw is! Map) {
      return null;
    }
    return AnswerNote.fromJson(raw.cast<String, Object?>());
  }

  Future<Object?> _readJson(String relativePath) async {
    final file = vault.file(relativePath);
    if (!file.existsSync()) {
      return null;
    }
    try {
      final String text = await file.readAsString();
      if (text.trim().isEmpty) {
        return null;
      }
      return jsonDecode(text);
    } on Object {
      return null;
    }
  }

  /// 把旧的 `layout/favorites.v1.json`（每卷一个 `question_ids` 列表）迁移进表。
  ///
  /// 幂等：靠 `question_id` 去重，已迁移的跳过；全部成功后删除旧文件，
  /// 否则「取消收藏后再启动」会把旧 id 又迁回来。
  ///
  /// 迁移只搬**元信息与溯源**（题号/题型/题干/区域/判题），不渲染题面图——
  /// 那一刻没有 PDF 上下文；题面图在看题页按需补（T8.3）。
  Future<int> migrateLegacy(Iterable<Workbook> workbooks) async {
    int migrated = 0;
    for (final Workbook workbook in workbooks) {
      final String path = VaultPaths.layoutFavorites(workbook.id);
      final List<String> ids = await _legacyIdsOf(path);
      if (ids.isEmpty) {
        continue;
      }
      final Map<String, QuestionBundle> bundles = <String, QuestionBundle>{
        for (final QuestionBundle bundle in await QuestionDao(
          db.raw,
        ).loadBundle(workbook.id))
          bundle.question.id: bundle,
      };
      final GradingData grading = GradingData.fromJson(
        await layout.readGrading(workbook.id),
      );

      for (final String questionId in ids) {
        if (await _dao.idByQuestionId(questionId) != null) {
          continue;
        }
        final QuestionBundle? bundle = bundles[questionId];
        if (bundle == null || bundle.slices.isEmpty) {
          // 题已经不在（重切删了），跳过这条旧收藏。
          continue;
        }
        final Question question = bundle.question;
        final QuestionSlice slice = bundle.slices.first;
        await capture(
          FavoriteCapture(
            questionId: question.id,
            workbookId: workbook.id,
            workbookTitle: workbook.title,
            label: question.label ?? '${question.ordinal}',
            ordinal: question.ordinal,
            kind: question.kind,
            stemText: question.stemText ?? '',
            pageIndex: slice.pageIndex,
            rect: slice.rect,
            verdict: grading.verdictOf(question.id),
          ),
        );
        migrated++;
      }
      // 迁移完删旧文件，避免「取消收藏后被迁回来」。
      final file = vault.file(path);
      if (file.existsSync()) {
        await file.delete();
      }
    }
    return migrated;
  }

  Future<List<String>> _legacyIdsOf(String path) async {
    final file = vault.file(path);
    if (!file.existsSync()) {
      return const <String>[];
    }
    try {
      final String raw = await file.readAsString();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const <String>[];
      }
      final Object? ids = decoded['question_ids'];
      if (ids is! List) {
        return const <String>[];
      }
      return <String>[
        for (final Object? id in ids)
          if (id is String && id.isNotEmpty) id,
      ];
    } on Object {
      return const <String>[];
    }
  }
}

/// 收藏那一刻要定格的数据（由 reader 侧准备好，store 只负责落盘）。
///
/// 图片与 JSON 都可空：题面图/作答图渲染失败、没判过题、没聊过 AI 时，
/// 收藏仍成立，只是看题页少一部分展示。
class FavoriteCapture {
  const FavoriteCapture({
    required this.questionId,
    required this.workbookId,
    required this.workbookTitle,
    required this.label,
    required this.ordinal,
    required this.kind,
    required this.stemText,
    required this.pageIndex,
    required this.rect,
    this.verdict = AnswerVerdict.none,
    this.knowledgeTags = const <String>[],
    this.stemPng,
    this.answerPng,
    this.chatJson,
    this.gradingJson,
    this.answerJson,
  });

  final String questionId;
  final String workbookId;
  final String workbookTitle;
  final String label;
  final int ordinal;
  final String kind;
  final String stemText;
  final int pageIndex;
  final RegionRect rect;
  final AnswerVerdict verdict;
  final List<String> knowledgeTags;

  /// 题面裁切（纯题面，不含笔迹）。
  final Uint8List? stemPng;

  /// 作答图（含笔迹）。
  final Uint8List? answerPng;

  /// AI 对话快照（`{turns: [...]}`）。
  final Map<String, Object?>? chatJson;

  /// 判题结论快照（QuestionGrade）。
  final Map<String, Object?>? gradingJson;

  /// 答案快照（AnswerNote）。
  final Map<String, Object?>? answerJson;
}
