/// Vault 里所有路径的**唯一拼装入口**（规格 T1.3）。
///
/// 规则：
/// 1. 除本文件外，任何地方都不许手写 `workbooks/xxx/yyy` 这种字符串。
/// 2. 这里全部是**相对路径**（相对 Vault 根）。绝对路径只在 [Vault] 里拼一次。
/// 3. 路径是数据契约：改了老用户的文件就找不到，等同于丢数据。
library;

abstract final class VaultPaths {
  static const String workbooksRoot = 'workbooks';

  static String workbookDir(String workbookId) => '$workbooksRoot/$workbookId';

  /// 原卷。导出与"原图查看"都读它，任何时候不许被滤镜污染。
  static String sourcePdf(String workbookId) =>
      '${workbookDir(workbookId)}/source.pdf';

  /// 复制中的临时文件。写它 → fsync → rename 成 [sourcePdf]，避免半个文件。
  static String sourcePdfTemp(String workbookId) =>
      '${workbookDir(workbookId)}/source.pdf.tmp';

  /// 人可读的冗余元数据。**以数据库为准**，这个只是给文件管理器看的。
  static String metaJson(String workbookId) =>
      '${workbookDir(workbookId)}/meta.json';

  static String thumbDir(String workbookId) =>
      '${workbookDir(workbookId)}/thumb';

  /// 缩略图。**0-based 页码，补零到 3 位**，保证目录里按文件名排序 = 按页序。
  static String thumb(String workbookId, int pageIndex) =>
      '${thumbDir(workbookId)}/${thumbName(pageIndex)}';

  static String thumbName(int pageIndex) =>
      'p${pageIndex.toString().padLeft(3, '0')}.png';

  /// 切题产物目录（L0–L2 的缓存）。T3.x 写入。
  static String layoutDir(String workbookId) =>
      '${workbookDir(workbookId)}/layout';

  /// **自动结果，只读**：文本层（L0）。可随时删掉重建，删了就会重新抽取。
  static String layoutText(String workbookId) =>
      '${layoutDir(workbookId)}/text.json';

  /// **自动结果，只读**：切出来的题目区域（L1/L2）。用户编辑不许改它。
  static String layoutRegions(String workbookId) =>
      '${layoutDir(workbookId)}/regions.v1.json';

  /// **用户覆盖层**（T3.4）：拖动/合并/锁定都写这里，重算自动结果时保留。
  static String layoutCorrections(String workbookId) =>
      '${layoutDir(workbookId)}/corrections.json';

  /// 文末答案区抽出的答案（label → 文本）。**自动结果，可重抽**。
  static String layoutAnswers(String workbookId) =>
      '${layoutDir(workbookId)}/answers.v1.json';

  /// AI 补出来的参考答案（用户产物）。**重切题不得覆盖**：
  /// 它和 `answers.v1.json`（PDF 答案，可重抽）分开存，读数时 AI 只补缺。
  static String layoutAnswersAi(String workbookId) =>
      '${layoutDir(workbookId)}/answers_ai.v1.json';

  /// 作答框 + 本地识别文本/原图（2026-10-24）。**用户产物，重切题时保留**。
  static String layoutAnswerSheet(String workbookId) =>
      '${layoutDir(workbookId)}/answer_sheet.v1.json';

  /// 作答原图目录（PDF 裁切 + 笔迹），后续给 AI/判题用。
  static String answerCrop(String workbookId, String questionId) =>
      '${layoutDir(workbookId)}/answer_crops/${_safeId(questionId)}.png';

  /// 仅笔迹的白底导出（不含题目信息）。
  static String answerInkExport(String workbookId, String questionId) =>
      '${layoutDir(workbookId)}/answer_crops/${_safeId(questionId)}_ink.png';

  /// 答题卡画布导出（含题目时用；答题卡自己的 1000×600 坐标）。
  static String answerSheetExport(String workbookId, String questionId) =>
      '${layoutDir(workbookId)}/answer_crops/${_safeId(questionId)}_sheet.png';

  /// 手动题目顺序（用户拖动排序），重切题时保留。
  static String layoutQuestionOrder(String workbookId) =>
      '${layoutDir(workbookId)}/question_order.v1.json';

  /// 判题（改卷）结果：`questionId → 对/错/待判`。用户手改的不会被自动判覆盖。
  static String layoutGrading(String workbookId) =>
      '${layoutDir(workbookId)}/grading.v1.json';

  /// 收藏的题目 id 列表（错题本接入前的落点，v6 起废弃，只用于迁移）。
  static String layoutFavorites(String workbookId) =>
      '${layoutDir(workbookId)}/favorites.v1.json';

  /// 收藏库根目录（顶层，与 workbooks 平级）。
  ///
  /// 为什么不用卷内 layout：收藏要**跨卷**、且**原卷删除后仍保留**，
  /// 所以放在卷目录外。孤儿清理只扫 `workbooks/`，不会误伤这里。
  static const String favoritesRoot = 'favorites';

  static String favoriteDir(String favoriteId) => '$favoritesRoot/$favoriteId';

  /// 题面裁切（纯题面，不含笔迹）。
  static String favoriteStem(String favoriteId) =>
      '${favoriteDir(favoriteId)}/stem.png';

  /// 作答图（含笔迹，供「看题页」展示）。
  static String favoriteAnswerImg(String favoriteId) =>
      '${favoriteDir(favoriteId)}/answer.png';

  /// AI 对话快照（该题 ChatTurn 列表）。
  static String favoriteChat(String favoriteId) =>
      '${favoriteDir(favoriteId)}/chat.json';

  /// 判题结论快照（QuestionGrade）。
  static String favoriteGrading(String favoriteId) =>
      '${favoriteDir(favoriteId)}/grading.json';

  /// 答案快照（AnswerNote，可能为空文件）。
  static String favoriteAnswer(String favoriteId) =>
      '${favoriteDir(favoriteId)}/answer.json';

  /// 答题卡笔迹快照（第 [paperIndex] 张，供二刷继续编辑；T8.3b 起用）。
  static String favoriteInkSif(String favoriteId, [int paperIndex = 0]) =>
      '${favoriteDir(favoriteId)}/ink/${paperIndex <= 0 ? 'p0' : 'p$paperIndex'}.sif';

  /// 二刷笔迹的上一版备份（写坏时回退，口径同 PDF 页笔迹）。
  static String favoriteInkSifBackup(String favoriteId, [int paperIndex = 0]) =>
      '${favoriteInkSif(favoriteId, paperIndex)}.bak';

  /// 收藏重刷的答题纸配置（尺寸/方向/张数/纸样式）。每道收藏一份。
  static String favoriteRedoPaper(String favoriteId) =>
      '${favoriteDir(favoriteId)}/paper.json';

  /// 「问 AI」的对话历史（按题存，用户产物）。**重切题不得覆盖**。
  static String layoutAiChat(String workbookId) =>
      '${layoutDir(workbookId)}/ai_chat.v1.json';

  /// 答题卡纸张配置（全局默认 + 每题覆盖）。
  static String layoutAnswerPaper(String workbookId) =>
      '${layoutDir(workbookId)}/answer_paper.v1.json';

  /// 答题卡里的手写笔迹（每道题一份 SIF，和 PDF 页笔迹分开）。
  /// 按 session 分开：二刷不会覆盖第一次的作答。
  static String answerInkDir(String workbookId, String sessionId) =>
      '${sessionDir(workbookId, sessionId)}/answers';

  /// 第 [paperIndex] 张的笔迹文件。
  ///
  /// 第 0 张沿用老文件名 `<qid>.sif`（此前的作答天然兼容），
  /// 之后是 `<qid>_p1.sif`、`<qid>_p2.sif`…… 序号即张数顺序。
  static String answerInk(
    String workbookId,
    String sessionId,
    String questionId, [
    int paperIndex = 0,
  ]) {
    final String id = _safeId(questionId);
    final String name = paperIndex <= 0 ? '$id.sif' : '${id}_p$paperIndex.sif';
    return '${answerInkDir(workbookId, sessionId)}/$name';
  }

  static String answerInkBackup(
    String workbookId,
    String sessionId,
    String questionId, [
    int paperIndex = 0,
  ]) => '${answerInk(workbookId, sessionId, questionId, paperIndex)}.bak';

  /// 一次作答的全部产物。`sessionId` 而不是 `seq`：二刷的目录必须唯一。
  static String sessionDir(String workbookId, String sessionId) =>
      '${workbookDir(workbookId)}/sessions/$sessionId';

  /// 全部作答目录（回填作答记录时要枚举，2026-10-25）。
  static String sessionsRoot(String workbookId) =>
      '${workbookDir(workbookId)}/sessions';

  /// 个人空间（记录页页首）根目录，与 workbooks / favorites 平级。
  ///
  /// 和卷无关：头像是"这个 app 的主人"，不是某一卷的附属物。
  static const String profileRoot = 'profile';

  /// 头像原图。**不重编码**：直接收编用户选的文件，
  /// 后缀统一 `.img` 是为了不撒谎（原文件可能是 jpg/png/webp/heic）。
  /// 渲染侧只认字节，Flutter 的解码器自己嗅探格式。
  static String profileAvatar() => '$profileRoot/avatar.img';

  /// 页首背景原图（同上，不重编码；渲染时用 cacheWidth 约束解码内存）。
  static String profileCover() => '$profileRoot/cover.img';

  /// 用户反馈草稿（本机暂存，等反馈通道接通）。
  ///
  /// 放在 `profile/` 之外、与卷平级：它是"这个人给产品的留言"，
  /// 不属于任何一卷；清理缓存时必须**不碰**这里（用户写的东西不是缓存）。
  static const String feedbackRoot = 'feedback';

  /// 一条反馈的正文 + 元数据（JSON）。
  static String feedbackDraft(String id) => '$feedbackRoot/$id.json';

  /// 反馈附图（第 [index] 张，0 起）。原样保存用户挑的字节。
  static String feedbackImage(String id, int index) =>
      '$feedbackRoot/$id-$index.img';

  /// 笔迹（SIF）。T2.4 写入。
  static String inkDir(String workbookId, String sessionId) =>
      '${sessionDir(workbookId, sessionId)}/ink';

  static String inkFile(String workbookId, String sessionId, int pageIndex) =>
      '${inkDir(workbookId, sessionId)}/p${pageIndex.toString().padLeft(3, '0')}.sif';

  /// 原子写的临时文件（写完 rename 成 [inkFile]）。
  static String inkFileTemp(
    String workbookId,
    String sessionId,
    int pageIndex,
  ) => '${inkFile(workbookId, sessionId, pageIndex)}.tmp';

  /// 上一版备份（每次成功写入前把旧 [inkFile] rename 成它）。
  static String inkFileBackup(
    String workbookId,
    String sessionId,
    int pageIndex,
  ) => '${inkFile(workbookId, sessionId, pageIndex)}.bak';

  /// 交卷快照与分析产物。T5.x 写入。
  static String exportDir(String workbookId) =>
      '${workbookDir(workbookId)}/exports';

  /// 长按题面预览保存的题目图片（导出产物，可被文件管理器取走）。
  static String exportQuestionImage(String workbookId, String questionId) =>
      '${exportDir(workbookId)}/question_images/${_safeId(questionId)}.png';

  /// 从相对路径反推 workbook id（孤儿清理要用）。
  /// `workbooks/<id>/...` → `<id>`；不匹配返回 null。
  static String? workbookIdOf(String relativePath) {
    final List<String> parts = relativePath.split('/');
    if (parts.length < 2 || parts.first != workbooksRoot) {
      return null;
    }
    final String id = parts[1];
    return id.isEmpty ? null : id;
  }

  /// 文件名里只允许字母数字、下划线和短横线：题目 id 是 ULID，但防御性处理。
  static String _safeId(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
}
