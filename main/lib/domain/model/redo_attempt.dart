/// 一次「重刷」的元数据（纯 Dart）。
///
/// 2026-10-26 用户口径：重刷不是"把同一份笔迹再写一遍"，而是**每次一个独立 attempt**：
/// - 点「重刷」打开空白新答题卡；
/// - 退出时问是否保存这一次；
/// - 收藏题处按列表展示每一次，可打开继续修改；
/// - 组卷里刷的要把组卷名与时间一起留下。
///
/// 元数据落 `favorites/<id>/redo/<attemptId>/meta.json`，笔迹与纸张同目录。
/// `attemptId` 在一次组卷连刷里由所有题共用（= runId），时间线与"本次"口径一致。
class RedoAttempt {
  const RedoAttempt({
    required this.id,
    required this.favoriteId,
    required this.createdAt,
    required this.updatedAt,
    this.setId = '',
    this.setTitle = '',
    this.saved = false,
    this.paperPages = 1,
    this.paperSummary = '',
  });

  factory RedoAttempt.fromJson(Map<String, Object?> json) => RedoAttempt(
    id: (json['id'] as String?) ?? '',
    favoriteId: (json['favorite_id'] as String?) ?? '',
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
    setId: (json['set_id'] as String?) ?? '',
    setTitle: (json['set_title'] as String?) ?? '',
    saved: json['saved'] == true,
    paperPages: (json['paper_pages'] as num?)?.toInt() ?? 1,
    paperSummary: (json['paper_summary'] as String?) ?? '',
  );

  final String id;
  final String favoriteId;

  /// 本地毫秒时间戳。
  final int createdAt;
  final int updatedAt;

  final String setId;
  final String setTitle;

  /// 用户是否确认保存过这一次。false = 草稿（App 被杀/还没退出）。
  final bool saved;

  final int paperPages;

  /// 纸张摘要（A4 · 横向 · 点阵 · 2 张），列表直接显示，不读 paper.json。
  final String paperSummary;

  bool get isSet => setId.isNotEmpty || setTitle.isNotEmpty;

  bool get isDraft => !saved;

  DateTime get createdAtTime =>
      DateTime.fromMillisecondsSinceEpoch(createdAt);

  DateTime get updatedAtTime =>
      DateTime.fromMillisecondsSinceEpoch(updatedAt);

  RedoAttempt copyWith({
    int? updatedAt,
    String? setId,
    String? setTitle,
    bool? saved,
    int? paperPages,
    String? paperSummary,
  }) => RedoAttempt(
    id: id,
    favoriteId: favoriteId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    setId: setId ?? this.setId,
    setTitle: setTitle ?? this.setTitle,
    saved: saved ?? this.saved,
    paperPages: paperPages ?? this.paperPages,
    paperSummary: paperSummary ?? this.paperSummary,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'id': id,
    'favorite_id': favoriteId,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'set_id': setId,
    'set_title': setTitle,
    'saved': saved,
    'paper_pages': paperPages,
    'paper_summary': paperSummary,
  };
}
