/// 用户对题目区域的修改（**覆盖层**，纯 Dart，可单测）。
///
/// ## 为什么是"操作列表"而不是"最终快照"
/// 1. 撤销 = 弹掉最后一条再重算，不需要为每种操作单独写 revert；
/// 2. 重切之后可以把同一条操作重新 apply 到新的自动结果上（快照就废了）；
/// 3. 文件小、可读、可审计（出问题能看出用户当时点了什么）。
///
/// ## 唯一真理
/// `layout/regions.v1.json` 是自动结果，**永远只读**；用户改了什么都写进
/// `layout/corrections.json`。读取时 `effective = applyAll(auto, ops)`。
/// 直接改自动结果的话，下次重切全丢（规格 04 §T3.4 点名的坑）。
library;

import 'dart:math' as math;

import 'package:shuaqi/domain/region/edited_question.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/split.dart';

/// 覆盖层格式版本。只加字段不改语义。
const int kCorrectionVersion = 1;

/// 一条修改。
sealed class RegionCorrection {
  const RegionCorrection({required this.id, required this.key});

  /// 稳定 id（ULID）。日志与调试用，也便于将来做"重放到某一步"。
  final String id;

  /// 目标题的 anchor key（见 `edited_question.dart`）。
  final String key;

  /// 正向执行。不修改入参。
  List<EditedQuestion> apply(List<EditedQuestion> questions);

  Map<String, Object?> toJson();

  /// 日志用的一句话（不含用户内容）。
  String get debugLabel;

  static RegionCorrection? fromJson(Map<String, Object?> json) {
    final String? type = json['t'] as String?;
    final String id = (json['id'] as String?) ?? '';
    final String key = (json['key'] as String?) ?? '';
    switch (type) {
      case 'move':
        return MoveCorrection(
          id: id,
          key: key,
          page: (json['page'] as num?)?.toInt() ?? 0,
          dx: (json['dx'] as num?)?.toDouble() ?? 0,
          dy: (json['dy'] as num?)?.toDouble() ?? 0,
        );
      case 'resize':
        return ResizeCorrection(
          id: id,
          key: key,
          page: (json['page'] as num?)?.toInt() ?? 0,
          rect: RegionRect.fromJson(
            (json['rect'] as Map<String, Object?>?) ??
                const <String, Object?>{},
          ),
        );
      case 'addSlice':
        return AddSliceCorrection(
          id: id,
          key: key,
          page: (json['page'] as num?)?.toInt() ?? 0,
          rect: RegionRect.fromJson(
            (json['rect'] as Map<String, Object?>?) ??
                const <String, Object?>{},
          ),
        );
      case 'removeSlice':
        return RemoveSliceCorrection(
          id: id,
          key: key,
          page: (json['page'] as num?)?.toInt() ?? 0,
        );
      case 'add':
        return AddQuestionCorrection(
          id: id,
          key: key,
          label: (json['label'] as String?) ?? '新增',
          rect: RegionRect.fromJson(
            (json['rect'] as Map<String, Object?>?) ??
                const <String, Object?>{},
          ),
          page: (json['page'] as num?)?.toInt() ?? 0,
        );
      case 'delete':
        return DeleteCorrection(id: id, key: key);
      case 'merge':
        return MergeCorrection(
          id: id,
          key: key,
          fromKey: (json['from'] as String?) ?? '',
        );
      case 'split':
        return SplitCorrection(
          id: id,
          key: key,
          page: (json['page'] as num?)?.toInt() ?? 0,
          atY: (json['atY'] as num?)?.toDouble() ?? 0,
        );
      case 'rename':
        return RenameCorrection(
          id: id,
          key: key,
          label: (json['label'] as String?) ?? '',
        );
      case 'lock':
        return LockCorrection(
          id: id,
          key: key,
          value: (json['v'] as num?)?.toInt() != 0,
        );
      case 'confirm':
        return ConfirmQuestionCorrection(id: id, key: key);
      default:
        return null;
    }
  }
}

/// 拖动整个框（当前页那一段）。
class MoveCorrection extends RegionCorrection {
  const MoveCorrection({
    required super.id,
    required super.key,
    required this.page,
    required this.dx,
    required this.dy,
  });

  final int page;
  final double dx;
  final double dy;

  @override
  List<EditedQuestion> apply(List<EditedQuestion> questions) =>
      _updateSlice(questions, key, page, (RegionRect rect) {
        // 只保留下限，不在这里做页内夹取：拖动过程要跟手，越界由调用方夹。
        return RegionRect.fromLTRB(
          math.max(0, rect.left + dx),
          math.max(0, rect.top + dy),
          math.max(12, rect.right + dx),
          math.max(12, rect.bottom + dy),
        );
      });

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'move',
    'id': id,
    'key': key,
    'page': page,
    'dx': (dx * 100).round() / 100,
    'dy': (dy * 100).round() / 100,
  };

  @override
  String get debugLabel => 'move p$page (${dx.round()},${dy.round()})';
}

/// 缩放（拖边/拖角）。
class ResizeCorrection extends RegionCorrection {
  const ResizeCorrection({
    required super.id,
    required super.key,
    required this.page,
    required this.rect,
  });

  final int page;
  final RegionRect rect;

  @override
  List<EditedQuestion> apply(List<EditedQuestion> questions) =>
      _updateSlice(questions, key, page, (RegionRect _) => rect);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'resize',
    'id': id,
    'key': key,
    'page': page,
    'rect': rect.toJson(),
  };

  @override
  String get debugLabel => 'resize p$page';
}

/// 给某题在另一页加一段（跨页题：延伸到下一页）。
class AddSliceCorrection extends RegionCorrection {
  const AddSliceCorrection({
    required super.id,
    required super.key,
    required this.page,
    required this.rect,
  });

  final int page;
  final RegionRect rect;

  @override
  List<EditedQuestion> apply(List<EditedQuestion> questions) {
    return _mapQuestion(questions, key, (EditedQuestion question) {
      final List<PageSlice> slices = <PageSlice>[
        for (final PageSlice slice in question.slices)
          if (slice.pageIndex != page) slice,
        PageSlice(pageIndex: page, rect: rect),
      ]..sort((PageSlice a, PageSlice b) => a.pageIndex.compareTo(b.pageIndex));
      // 分段加了，anchor 会变：把 key 重算，后续 op 才能继续对上。
      return question
          .copyWith(slices: slices)
          .withKey(regionKeyOf(question.label, slices));
    });
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'addSlice',
    'id': id,
    'key': key,
    'page': page,
    'rect': rect.toJson(),
  };

  @override
  String get debugLabel => 'addSlice p$page';
}

/// 去掉某题在某一页的那一段。
class RemoveSliceCorrection extends RegionCorrection {
  const RemoveSliceCorrection({
    required super.id,
    required super.key,
    required this.page,
  });

  final int page;

  @override
  List<EditedQuestion> apply(List<EditedQuestion> questions) {
    return _mapQuestion(questions, key, (EditedQuestion question) {
      final List<PageSlice> slices = <PageSlice>[
        for (final PageSlice slice in question.slices)
          if (slice.pageIndex != page) slice,
      ];
      return question
          .copyWith(slices: slices)
          .withKey(regionKeyOf(question.label, slices));
    });
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'removeSlice',
    'id': id,
    'key': key,
    'page': page,
  };

  @override
  String get debugLabel => 'removeSlice p$page';
}

/// 手画一个新框。
class AddQuestionCorrection extends RegionCorrection {
  const AddQuestionCorrection({
    required super.id,
    required super.key,
    required this.label,
    required this.rect,
    required this.page,
  });

  final String label;
  final RegionRect rect;
  final int page;

  @override
  List<EditedQuestion> apply(List<EditedQuestion> questions) {
    final int ordinal = questions.fold<int>(
      1,
      (int max, EditedQuestion q) => math.max(max, q.ordinal + 1),
    );
    final List<PageSlice> slices = <PageSlice>[
      PageSlice(pageIndex: page, rect: rect),
    ];
    return <EditedQuestion>[
      ...questions,
      EditedQuestion(
        key: key.isEmpty ? regionKeyOf(label, slices) : key,
        ordinal: ordinal,
        label: label,
        level: 2,
        kind: 'unknown',
        stem: '',
        // 用户亲手画的框不需要"置信度"：它不是推断结果。
        confidence: 1,
        slices: slices,
        userAdded: true,
      ),
    ];
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'add',
    'id': id,
    'key': key,
    'label': label,
    'page': page,
    'rect': rect.toJson(),
  };

  @override
  String get debugLabel => 'add "$label" p$page';
}

/// 把「不确定 / 容器」框**就地确认为一道题**（2026-10-27 用户反馈）。
///
/// ## 为什么需要它
/// 切题拿不准时会给一个 **level 1 的虚线框**（"这一块可能是大题容器，也可能是
/// 一道题"）。用户在题目面板里点「加题」，意思明明是：
///
/// > 这一块**就是这道题**，把虚线去掉、认作题目。
///
/// 但旧实现走的是 [AddQuestionCorrection] + [DeleteCorrection]：
/// 新题的题号取"现有最大号 +1"，再删掉原来那个虚线框 ——
/// 于是题号变了、在面板里也跳到了列表末尾，和用户意图相反。
///
/// ## 语义
/// 只改三件事，其余**一律不动**：
/// - `level` 1 → 2（虚线 → 实线，开始计入可作答的单题）；
/// - `confidence` → 1（用户已经确认过，不再是"不确定"）；
/// - 删除/新增都不做：`key`、`ordinal`、`label`、`slices` 原样保留，
///   所以**题号不变、面板里的位置不变、题目 id 也不变**
///   （`RegionBuilder` 按 anchor key 复用旧 id，判题/收藏/记录都不会断）。
class ConfirmQuestionCorrection extends RegionCorrection {
  const ConfirmQuestionCorrection({required super.id, required super.key});

  @override
  List<EditedQuestion> apply(List<EditedQuestion> questions) => _mapQuestion(
    questions,
    key,
    (EditedQuestion question) => question.copyWith(level: 2, confidence: 1),
  );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'confirm',
    'id': id,
    'key': key,
  };

  @override
  String get debugLabel => 'confirm';
}

/// 删除（软删除：保留记录，重切后还能按 anchor 找回来）。
class DeleteCorrection extends RegionCorrection {
  const DeleteCorrection({required super.id, required super.key});

  @override
  List<EditedQuestion> apply(List<EditedQuestion> questions) => _mapQuestion(
    questions,
    key,
    (EditedQuestion question) => question.copyWith(deleted: true),
  );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'delete',
    'id': id,
    'key': key,
  };

  @override
  String get debugLabel => 'delete';
}

/// 合并：把 [fromKey] 的区域并入本题，被合并者标记删除。
class MergeCorrection extends RegionCorrection {
  const MergeCorrection({
    required super.id,
    required super.key,
    required this.fromKey,
  });

  final String fromKey;

  @override
  List<EditedQuestion> apply(List<EditedQuestion> questions) {
    final int into = _resolve(questions, key);
    final int from = _resolve(questions, fromKey);
    if (into < 0 || from < 0 || into == from) {
      return questions;
    }
    final EditedQuestion source = questions[from];
    final EditedQuestion target = questions[into];
    // 同页取并集，不同页直接追加（跨页合并）。
    final Map<int, RegionRect> byPage = <int, RegionRect>{};
    for (final PageSlice slice in target.slices) {
      byPage[slice.pageIndex] = slice.rect;
    }
    for (final PageSlice slice in source.slices) {
      final RegionRect? existing = byPage[slice.pageIndex];
      byPage[slice.pageIndex] = existing == null
          ? slice.rect
          : existing.union(slice.rect);
    }
    final List<PageSlice> slices = <PageSlice>[
      for (final MapEntry<int, RegionRect> entry in byPage.entries)
        PageSlice(pageIndex: entry.key, rect: entry.value),
    ]..sort((PageSlice a, PageSlice b) => a.pageIndex.compareTo(b.pageIndex));

    final List<EditedQuestion> next = List<EditedQuestion>.of(questions);
    next[into] = target
        .copyWith(slices: slices)
        .withKey(regionKeyOf(target.label, slices));
    next[from] = source.copyWith(deleted: true);
    return next;
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'merge',
    'id': id,
    'key': key,
    'from': fromKey,
  };

  @override
  String get debugLabel => 'merge';
}

/// 拆分：在某页的 [atY] 处把本题切成上下两段，下半段成为新题。
class SplitCorrection extends RegionCorrection {
  const SplitCorrection({
    required super.id,
    required super.key,
    required this.page,
    required this.atY,
  });

  final int page;
  final double atY;

  @override
  List<EditedQuestion> apply(List<EditedQuestion> questions) {
    final int index = _resolve(questions, key);
    if (index < 0) {
      return questions;
    }
    final EditedQuestion question = questions[index];
    PageSlice? target;
    for (final PageSlice slice in question.slices) {
      if (slice.pageIndex == page) {
        target = slice;
        break;
      }
    }
    if (target == null) {
      return questions;
    }
    final RegionRect rect = target.rect;
    // 切点离上下边太近就没有意义（会切出 12pt 以下的碎片）。
    if (atY <= rect.top + 12 || atY >= rect.bottom - 12) {
      return questions;
    }
    final RegionRect upper = RegionRect.fromLTRB(
      rect.left,
      rect.top,
      rect.right,
      atY,
    );
    final RegionRect lower = RegionRect.fromLTRB(
      rect.left,
      atY,
      rect.right,
      rect.bottom,
    );
    final List<PageSlice> upperSlices = <PageSlice>[
      for (final PageSlice slice in question.slices)
        if (slice.pageIndex == page)
          PageSlice(pageIndex: page, rect: upper)
        else
          slice,
    ];
    final List<PageSlice> lowerSlices = <PageSlice>[
      PageSlice(pageIndex: page, rect: lower),
    ];
    final int ordinal = questions.fold<int>(
      1,
      (int max, EditedQuestion q) => math.max(max, q.ordinal + 1),
    );
    final String label = '${question.label}·下';
    final List<EditedQuestion> next = List<EditedQuestion>.of(questions);
    next[index] = question
        .copyWith(slices: upperSlices)
        .withKey(regionKeyOf(question.label, upperSlices));
    next.add(
      EditedQuestion(
        key: regionKeyOf(label, lowerSlices),
        ordinal: ordinal,
        label: label,
        level: question.level,
        kind: question.kind,
        stem: '',
        confidence: 1,
        slices: lowerSlices,
        userAdded: true,
      ),
    );
    return next;
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'split',
    'id': id,
    'key': key,
    'page': page,
    'atY': (atY * 100).round() / 100,
  };

  @override
  String get debugLabel => 'split p$page @${atY.round()}';
}

/// 改题号（2026-10-23：浮动条上"题号可改"）。
///
/// 为什么值得单独一条 op：扫描件/版面切块认不出数字，标签只是序号；
/// 用户手填一个"12."之后，这一题在第 4 周喂给 AI 时才有真正的题号。
///
/// 改标签会改 anchor key（key = 题号|页|y），所以 apply 完必须重算 key，
/// 否则后续 op 会对不上（拖动会重算 key，改标签不会）。
class RenameCorrection extends RegionCorrection {
  const RenameCorrection({
    required super.id,
    required super.key,
    required this.label,
  });

  final String label;

  @override
  List<EditedQuestion> apply(List<EditedQuestion> questions) {
    return _mapQuestion(questions, key, (EditedQuestion question) {
      final EditedQuestion renamed = question.copyWith(label: label);
      return renamed.withKey(regionKeyOf(label, renamed.slices));
    });
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'rename',
    'id': id,
    'key': key,
    'label': label,
  };

  @override
  String get debugLabel => 'rename "$label"';
}

/// 锁定 / 解锁。锁定的框不参与后续自动重算（T3.4 起生效）。
class LockCorrection extends RegionCorrection {
  const LockCorrection({
    required super.id,
    required super.key,
    required this.value,
  });

  final bool value;

  @override
  List<EditedQuestion> apply(List<EditedQuestion> questions) => _mapQuestion(
    questions,
    key,
    (EditedQuestion question) => question.copyWith(locked: value),
  );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    't': 'lock',
    'id': id,
    'key': key,
    'v': value ? 1 : 0,
  };

  @override
  String get debugLabel => value ? 'lock' : 'unlock';
}

/// 覆盖层：一串有序操作 + 读写。
class CorrectionLog {
  const CorrectionLog(this.ops);

  static const CorrectionLog empty = CorrectionLog(<RegionCorrection>[]);

  /// 规格：编辑撤销 ≥50 步。这里同时是"文件最多留多少条操作"。
  static const int maxOps = 200;

  final List<RegionCorrection> ops;

  bool get isEmpty => ops.isEmpty;

  int get length => ops.length;

  CorrectionLog push(RegionCorrection op) {
    final List<RegionCorrection> next = <RegionCorrection>[...ops, op];
    if (next.length > maxOps) {
      next.removeRange(0, next.length - maxOps);
    }
    return CorrectionLog(next);
  }

  /// 撤销：弹掉最后一条（历史由重算决定，不需要每条自带的 revert）。
  CorrectionLog dropLast() =>
      ops.isEmpty ? this : CorrectionLog(ops.sublist(0, ops.length - 1));

  /// 把覆盖层应用到自动结果上。
  List<EditedQuestion> applyTo(List<EditedQuestion> base) {
    List<EditedQuestion> current = base;
    for (final RegionCorrection op in ops) {
      current = op.apply(current);
    }
    return current;
  }

  /// 锁定的题（重切时要保留它们的区域）。
  ///
  /// 必须按顺序折叠：同一题先 lock 后 unlock，最终是**解锁**，
  /// 只收集 `value == true` 会把它当成还锁着（单测第 9 例锁的就是这个）。
  Set<String> get lockedKeys {
    final Map<String, bool> state = <String, bool>{};
    for (final RegionCorrection op in ops) {
      if (op is LockCorrection) {
        state[op.key] = op.value;
      }
    }
    return <String>{
      for (final MapEntry<String, bool> entry in state.entries)
        if (entry.value) entry.key,
    };
  }

  Map<String, Object?> toJson(String workbookId) => <String, Object?>{
    'version': kCorrectionVersion,
    'workbook': workbookId,
    'ops': <Object?>[for (final RegionCorrection op in ops) op.toJson()],
  };

  static CorrectionLog fromJson(Map<String, Object?> json) {
    final Object? version = json['version'];
    if (version is! num || version.toInt() > kCorrectionVersion) {
      return empty;
    }
    final Object? rawOps = json['ops'];
    if (rawOps is! List<Object?>) {
      return empty;
    }
    final List<RegionCorrection> ops = <RegionCorrection>[];
    for (final Object? raw in rawOps) {
      if (raw is! Map<String, Object?>) {
        continue;
      }
      final RegionCorrection? op = RegionCorrection.fromJson(raw);
      if (op != null) {
        ops.add(op);
      }
    }
    return CorrectionLog(ops);
  }
}

// ── 内部工具 ──────────────────────────────────────────────────────────

/// 按 anchor 找题：先精确 key，再"同题号 + 同页 + y 差 ≤80pt"。
int _resolve(List<EditedQuestion> questions, String key) {
  for (int i = 0; i < questions.length; i++) {
    if (questions[i].key == key) {
      return i;
    }
  }
  final String label = normalizeLabel(anchorLabel(key));
  final int page = anchorPage(key);
  final double y = anchorY(key);
  int best = -1;
  double bestDistance = double.infinity;
  for (int i = 0; i < questions.length; i++) {
    final EditedQuestion question = questions[i];
    if (normalizeLabel(question.label) != label) {
      continue;
    }
    if (question.firstPage != page) {
      continue;
    }
    final double distance = (question.firstY - y).abs();
    if (distance <= 80 && distance < bestDistance) {
      best = i;
      bestDistance = distance;
    }
  }
  return best;
}

List<EditedQuestion> _mapQuestion(
  List<EditedQuestion> questions,
  String key,
  EditedQuestion Function(EditedQuestion question) transform,
) {
  final int index = _resolve(questions, key);
  if (index < 0) {
    // 悬空修改（重切后锚不上）：跳过，不抛、不删。
    return questions;
  }
  final List<EditedQuestion> next = List<EditedQuestion>.of(questions);
  next[index] = transform(next[index]);
  return next;
}

List<EditedQuestion> _updateSlice(
  List<EditedQuestion> questions,
  String key,
  int page,
  RegionRect Function(RegionRect rect) transform,
) {
  return _mapQuestion(questions, key, (EditedQuestion question) {
    bool changed = false;
    final List<PageSlice> slices = <PageSlice>[];
    for (final PageSlice slice in question.slices) {
      if (slice.pageIndex == page) {
        changed = true;
        slices.add(PageSlice(pageIndex: page, rect: transform(slice.rect)));
      } else {
        slices.add(slice);
      }
    }
    if (!changed) {
      return question;
    }
    return question
        .copyWith(slices: slices)
        .withKey(regionKeyOf(question.label, slices));
  });
}

extension on EditedQuestion {
  /// 换 key（分段变了 anchor 就变了，后续 op 才能继续对上）。
  EditedQuestion withKey(String nextKey) => EditedQuestion(
    key: nextKey,
    ordinal: ordinal,
    label: label,
    level: level,
    kind: kind,
    stem: stem,
    confidence: confidence,
    slices: slices,
    locked: locked,
    deleted: deleted,
    userAdded: userAdded,
    parentOrdinal: parentOrdinal,
  );
}

/// 这串操作**净增减了几道题**（不是操作步数）。
///
/// 2026-10-24 用户口径：面板要显示的"手改"信息是"题目增减了几道"；
/// 操作步数是后台/开发者看的调试数据，不该摆在题面上。
///
/// 只数真正改变题数的操作：新增 +1、切开 +1、删除 −1、并入 −1。
/// 移动/缩放/跨页补段/改题号/锁定都不改题数。
int questionDeltaOf(CorrectionLog log) {
  int delta = 0;
  for (final RegionCorrection op in log.ops) {
    if (op is AddQuestionCorrection || op is SplitCorrection) {
      delta += 1;
    } else if (op is DeleteCorrection || op is MergeCorrection) {
      delta -= 1;
    }
  }
  return delta;
}
