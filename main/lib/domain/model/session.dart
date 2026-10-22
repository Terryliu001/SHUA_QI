/// 一次作答会话（规格 §5.2 `session` 表）。
library;

/// 会话状态机（§5.5）：`draft --submit--> submitted --archive--> archived`。
///
/// 顺序是单向的，**没有回退路径**：交卷后不允许再改 draft，
/// 否则"快照不可变"（§5.2 `submission`）就失去意义。
enum SessionState {
  draft,
  submitted,
  archived;

  static SessionState parse(String? raw) {
    for (final SessionState value in SessionState.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return SessionState.draft;
  }
}

class Session {
  const Session({
    required this.id,
    required this.workbookId,
    required this.seq,
    required this.state,
    required this.startedAt,
    this.submittedAt,
    this.lastPage = 0,
  });

  factory Session.fromRow(Map<String, Object?> row) {
    return Session(
      id: row['id']! as String,
      workbookId: row['workbook_id']! as String,
      seq: (row['seq']! as num).toInt(),
      state: SessionState.parse(row['state'] as String?),
      startedAt: (row['started_at']! as num).toInt(),
      submittedAt: (row['submitted_at'] as num?)?.toInt(),
      lastPage: (row['last_page'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String workbookId;

  /// 同一卷的第几次作答，从 1 开始。二刷就是 seq=2，两条记录互不影响（REQ-11）。
  final int seq;

  final SessionState state;

  /// UTC 毫秒。
  final int startedAt;
  final int? submittedAt;

  /// 最后停留的页（0-based）。
  final int lastPage;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'workbook_id': workbookId,
    'seq': seq,
    'state': state.name,
    'started_at': startedAt,
    'submitted_at': submittedAt,
    'last_page': lastPage,
  };

  Session copyWith({
    SessionState? state,
    int? submittedAt,
    int? lastPage,
  }) {
    return Session(
      id: id,
      workbookId: workbookId,
      seq: seq,
      state: state ?? this.state,
      startedAt: startedAt,
      submittedAt: submittedAt ?? this.submittedAt,
      lastPage: lastPage ?? this.lastPage,
    );
  }

  @override
  String toString() => 'Session($workbookId#$seq ${state.name})';
}
