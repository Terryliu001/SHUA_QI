import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/records/profile_store.dart';
import 'package:shuaqi/domain/records/record_time.dart';
import 'package:shuaqi/domain/records/records_overview.dart';
import 'package:shuaqi/domain/records/records_stats.dart';
import 'package:shuaqi/state/record_providers.dart';
import 'package:shuaqi/state/shell_providers.dart';
import 'package:shuaqi/ui/records/profile_header.dart';
import 'package:shuaqi/ui/records/records_heatmap.dart';
import 'package:shuaqi/ui/records/records_stats_board.dart';
import 'package:shuaqi/ui/records/records_streak_card.dart';
import 'package:shuaqi/ui/records/records_word_cloud.dart';
import 'package:shuaqi/ui/records/timeline_page.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/empty_state.dart';
import 'package:shuaqi/ui/widgets/image_crop_sheet.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';

/// 记录 tab（阶段 9）—— **作答看板**，不是"个人主页"。
///
/// 定位（用户口径）：这里回答"我最近练得怎么样"，
/// 所以页首是"个人空间"（头像 / 昵称 / 格言 / 封面），
/// 主体是"统计"（热力图 + 科目词云 + 近期看板），
/// 出口是"作答时间线"（按天回看卷与题，一键回原卷）。
///
/// 与书架/收藏夹的分工：
/// - 书架 = 找卷、管理卷；收藏夹 = 找题、管理题集；
/// - 记录 = 看**自己的行为**，不做检索，只做回顾。
class RecordsPage extends ConsumerStatefulWidget {
  const RecordsPage({super.key, required this.onGoBookshelf});

  final VoidCallback onGoBookshelf;

  @override
  ConsumerState<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends ConsumerState<RecordsPage> {
  /// 页首实际宽度（含壳层侧栏占位）；裁封面按它算比例，不能用整块屏幕宽。
  final GlobalKey _headerKey = GlobalKey();

  /// 头像/封面写入后 +1：文件路径不变，必须换 Image Key 才会重新解码。
  int _profileImageEpoch = 0;

  /// 词云维度：默认按科目（文件夹），可切到题型。
  bool _cloudByKind = false;

  /// 热力图选中的那天（点格子看当天小结）。
  DateTime? _pickedDay;

  @override
  Widget build(BuildContext context) {
    // 切回「记录」tab 时刷新：IndexedStack 保活，页面不会自己重建，
    // 而在阅读器里写题不会有任何通知打到这个页面。
    ref.listen<int>(shellTabProvider, (int? prev, int next) {
      if (next == kRecordsTab && prev != kRecordsTab) {
        unawaited(_refresh());
      }
    });

    final AsyncValue<RecordsOverview> async = ref.watch(
      recordsOverviewProvider,
    );
    final AsyncValue<ProfileData> profileAsync = ref.watch(profileProvider);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: profileAsync.maybeWhen(
                data: (ProfileData profile) => RecordsProfileHeader(
                  key: _headerKey,
                  profile: profile,
                  avatarFile: ref.read(profileStoreProvider).avatarFile(),
                  coverFile: ref.read(profileStoreProvider).coverFile(),
                  onMenu: () => unawaited(_openMenu(profile)),
                  onEditText: () => unawaited(_editText(profile)),
                  onAvatarTap: () => unawaited(_openAvatarSheet(profile)),
                  imageEpoch: _profileImageEpoch,
                ),
                orElse: () => const SizedBox(height: 178),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                ShqSpace.lg,
                ShqSpace.lg,
                ShqSpace.lg,
                ShqSpace.huge,
              ),
              sliver: SliverToBoxAdapter(
                child: async.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: ShqSpace.huge),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (Object error, StackTrace stackTrace) => EmptyState(
                    icon: Icons.insights_outlined,
                    title: '记录暂时读不出来',
                    message: '统计出错了，下拉再试一次。',
                    actionLabel: '去书架',
                    onAction: widget.onGoBookshelf,
                  ),
                  data: (RecordsOverview overview) => _body(overview),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(RecordsOverview overview) {
    // 「今天」用**会自己走**的那个 provider（2026-10-26 用户第 8 条）：
    // 原来取 overview.generatedAt，provider 不刷新就一直停在旧日期，
    // 隔天再看热力图就会错位。
    final DateTime today = ref.watch(recordsTodayProvider);
    final Widget heat = _HeatCard(
      overview: overview,
      today: today,
      pickedDay: _pickedDay,
      onPick: (DateTime day) => setState(() => _pickedDay = day),
      onClear: () => setState(() => _pickedDay = null),
    );
    final Widget streak = RecordsStreakCard(
      streak: overview.streak,
      todayCount: overview.todayCount(RecordTime.dayKey(today)),
      dayStats: overview.dayStats,
      today: today,
    );
    final Widget cloud = _CloudCard(
      overview: overview,
      byKind: _cloudByKind,
      onToggle: () => setState(() => _cloudByKind = !_cloudByKind),
    );
    final Widget board = RecordsStatsBoard(
      overview: overview,
      onOpenTimeline: () => unawaited(_openTimeline()),
    );

    if (overview.isEmpty) {
      // 一条记录都没有：热力图/看板全是空壳，不如直接给一句能照做的话。
      // 个人空间仍然保留（用户可以先设头像/格言）。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          EmptyState(
            icon: Icons.assignment_outlined,
            title: '还没有作答记录',
            message: '去书架打开一卷，用答题卡做几道题——做过、判过的题都会记在这里。',
            actionLabel: '去书架',
            onAction: widget.onGoBookshelf,
          ),
          const SizedBox(height: ShqSpace.lg),
          streak,
          const SizedBox(height: ShqSpace.lg),
          heat,
          const SizedBox(height: ShqSpace.lg),
          cloud,
        ],
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 平板横屏（1200dp）左右 2:3；竖屏/窄屏（<900）改纵向，
        // 否则右栏三个大数字会被挤成两行。
        final bool wide = constraints.maxWidth >= 900;
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              heat,
              const SizedBox(height: ShqSpace.lg),
              cloud,
              const SizedBox(height: ShqSpace.lg),
              streak,
              const SizedBox(height: ShqSpace.lg),
              board,
            ],
          );
        }
        // 两栏底部必须对齐（2026-10-25 用户）：用 `IntrinsicHeight` 把两栏拉成
        // 同一高度，再让**最后一张卡**（词云 / 作答概览）吃掉剩余空间。
        // 不靠"给打卡卡补几像素"——那种对齐一改内容就又错开了。
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    heat,
                    const SizedBox(height: ShqSpace.lg),
                    Expanded(child: cloud),
                  ],
                ),
              ),
              const SizedBox(width: ShqSpace.lg),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    streak,
                    const SizedBox(height: ShqSpace.lg),
                    Expanded(child: board),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _refresh() async {
    ref.invalidate(profileProvider);
    ref.invalidate(recordsOverviewProvider);
    try {
      await ref.read(recordsOverviewProvider.future);
    } on Object {
      // 失败由 async.when 的 error 分支呈现，这里不重复弹提示。
    }
  }

  Future<void> _openTimeline() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const RecordsTimelinePage(),
      ),
    );
    if (mounted) {
      unawaited(_refresh());
    }
  }

  // ── 个人空间 ───────────────────────────────────────────────────────────

  Future<void> _openMenu(ProfileData profile) async {
    final _ProfileAction? action = await showModalBottomSheet<_ProfileAction>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _MenuRow(
              icon: Icons.account_circle_outlined,
              title: profile.hasAvatar ? '更换头像' : '设置头像',
              subtitle: '圆形头像显示在左下角',
              onTap: () => Navigator.pop(context, _ProfileAction.avatar),
            ),
            _MenuRow(
              icon: Icons.image_outlined,
              title: profile.hasCover ? '更换背景' : '设置背景',
              subtitle: '不设则跟随系统底色',
              onTap: () => Navigator.pop(context, _ProfileAction.cover),
            ),
            _MenuRow(
              icon: Icons.edit_outlined,
              title: '编辑昵称与格言',
              subtitle: profile.name.isEmpty ? '还没设昵称' : profile.name,
              onTap: () => Navigator.pop(context, _ProfileAction.text),
            ),
            if (profile.hasAvatar)
              _MenuRow(
                icon: Icons.person_off_outlined,
                title: '移除头像',
                onTap: () => Navigator.pop(context, _ProfileAction.clearAvatar),
              ),
            if (profile.hasCover)
              _MenuRow(
                icon: Icons.hide_image_outlined,
                title: '恢复默认底色',
                onTap: () => Navigator.pop(context, _ProfileAction.clearCover),
              ),
            const SizedBox(height: ShqSpace.sm),
          ],
        ),
      ),
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case _ProfileAction.avatar:
        await _pickImage(isAvatar: true);
      case _ProfileAction.cover:
        await _pickImage(isAvatar: false);
      case _ProfileAction.text:
        await _editText(profile);
      case _ProfileAction.clearAvatar:
        await _runProfile(() => ref.read(profileStoreProvider).clearAvatar());
      case _ProfileAction.clearCover:
        await _runProfile(() => ref.read(profileStoreProvider).clearCover());
    }
  }

  /// 点头像弹的浮层：先给一句"这里能换"，再给两个动作。
  ///
  /// 为什么不做成"点一下直接开相册"：直接开相册是个不可撤销的跳转
  /// （用户可能只是想看看现在用的是哪张图）；给一层浮层既解释了入口，
  /// 也让"移除头像"有地方站。
  Future<void> _openAvatarSheet(ProfileData profile) async {
    final ProfileStore store = ref.read(profileStoreProvider);
    final _AvatarAction? action = await showModalBottomSheet<_AvatarAction>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
      ),
      builder: (BuildContext context) {
        final ThemeData theme = Theme.of(context);
        final ColorScheme scheme = theme.colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: ShqSpace.xs),
              CircleAvatar(
                radius: 34,
                backgroundColor: scheme.surfaceContainerHighest,
                foregroundImage: profile.hasAvatar
                    ? FileImage(store.avatarFile())
                    : null,
                onForegroundImageError: (
                  Object error,
                  StackTrace? stackTrace,
                ) {},
                child: profile.hasAvatar
                    ? null
                    : Icon(
                        Icons.person_outline,
                        size: 30,
                        color: scheme.onSurfaceVariant,
                      ),
              ),
              const SizedBox(height: ShqSpace.sm),
              Text(
                profile.hasAvatar ? '更换你的头像' : '还没有头像',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: ShqSpace.xl),
                child: Text(
                  '选一张方一点的图最合适；它会显示在页首左下角。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: ShqSpace.sm),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从相册选择'),
                onTap: () => Navigator.pop(context, _AvatarAction.pick),
              ),
              if (profile.hasAvatar)
                ListTile(
                  leading: const Icon(Icons.person_off_outlined),
                  title: const Text('移除头像'),
                  onTap: () => Navigator.pop(context, _AvatarAction.clear),
                ),
              const SizedBox(height: ShqSpace.sm),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case _AvatarAction.pick:
        await _pickImage(isAvatar: true);
      case _AvatarAction.clear:
        await _runProfile(() => store.clearAvatar());
    }
  }

  /// 挑图 → **裁剪** → 收编进 Vault。
  ///
  /// 2026-10-26 用户第 3 条：上传之后要能给用户一个"确定裁哪一块"的窗口，
  /// 头像与背景图都一样。所以这里多一步裁剪：用户拖动/缩放取景框，
  /// 确认后写裁好的 PNG（取消 = 什么都不改）。
  Future<void> _pickImage({required bool isAvatar}) async {
    List<PlatformFile> picked = const <PlatformFile>[];
    try {
      picked = await FilePicker.pickFiles(type: FileType.image);
    } on Object {
      if (mounted) {
        _toast('打不开系统相册');
      }
      return;
    }
    if (picked.isEmpty || !mounted) {
      return;
    }
    final String? path = picked.first.path;
    if (path == null || path.isEmpty) {
      _toast('这张图读不出来，换一张试试');
      return;
    }
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } on Object {
      if (mounted) {
        _toast('这张图读不出来，换一张试试');
      }
      return;
    }
    if (!mounted) {
      return;
    }
    // 封面的取景比例 = 页首**实际**宽 : 230dp。
    // 不能用 MediaQuery.width：平板有左侧栏，实际页首比整屏窄；
    // 用整屏宽会把裁切框拉得比最终显示更宽，图在页首会被横向拉长。
    final Size? headerSize = _headerKey.currentContext?.size;
    final double headerWidth =
        headerSize?.width ?? MediaQuery.sizeOf(context).width;
    final double coverAspect = headerWidth / 230;
    final Uint8List? cropped = await showImageCropSheet(
      context,
      bytes: bytes,
      kind: isAvatar
          ? const CropKind.avatar()
          : CropKind.cover(aspectRatio: coverAspect),
    );
    if (cropped == null || !mounted) {
      return; // 用户取消：什么都不改。
    }
    await _runProfile(() async {
      final ProfileStore store = ref.read(profileStoreProvider);
      if (isAvatar) {
        await store.setAvatarBytes(cropped);
      } else {
        await store.setCoverBytes(cropped);
      }
    });
  }

  Future<void> _runProfile(Future<void> Function() action) async {
    try {
      await action();
      // 头像/封面写回的是**同一个文件路径**，Flutter 的 ImageCache 只认
      // provider（路径）不认 mtime：不清掉就会一直显示旧图，看起来像"裁剪没生效"。
      // 这里清内存缓存 + 正在显示的那一份，再让 profileProvider 重读。
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      if (mounted) {
        setState(() => _profileImageEpoch++);
      }
      ref.invalidate(profileProvider);
      if (mounted) {
        _toast('已更新');
      }
    } on Object catch (error) {
      if (mounted) {
        _toast('保存失败：$error');
      }
    }
  }

  /// 昵称 + 格言一起编辑：它们在同一块区域，分两次弹窗反而更麻烦。
  Future<void> _editText(ProfileData profile) async {
    final _TextResult? result = await showDialog<_TextResult>(
      context: context,
      builder: (BuildContext context) => _TextEditDialog(profile: profile),
    );
    if (result == null || !mounted) {
      return;
    }
    await _runProfile(() async {
      final ProfileStore store = ref.read(profileStoreProvider);
      await store.saveName(result.name);
      await store.saveMotto(result.motto);
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1600),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

enum _ProfileAction { avatar, cover, text, clearAvatar, clearCover }

enum _AvatarAction { pick, clear }

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return ListTile(
      leading: Icon(icon, color: scheme.onSurfaceVariant),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
      onTap: onTap,
    );
  }
}

class _TextResult {
  const _TextResult(this.name, this.motto);

  final String name;
  final String motto;
}

class _TextEditDialog extends StatefulWidget {
  const _TextEditDialog({required this.profile});

  final ProfileData profile;

  @override
  State<_TextEditDialog> createState() => _TextEditDialogState();
}

class _TextEditDialogState extends State<_TextEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.profile.name,
  );
  late final TextEditingController _motto = TextEditingController(
    text: widget.profile.motto,
  );

  @override
  void dispose() {
    _name.dispose();
    _motto.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('昵称与格言'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _name,
              maxLength: ProfileStore.maxNameLength,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '昵称',
                hintText: '比如：刷题的人',
                counterText: '',
              ),
            ),
            const SizedBox(height: ShqSpace.sm),
            TextField(
              controller: _motto,
              maxLength: ProfileStore.maxMottoLength,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                labelText: '格言',
                hintText: '写一句给自己的话',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: ShqSpace.xs),
            Text(
              '留空即不显示。昵称最多 ${ProfileStore.maxNameLength} 字，'
              '格言最多 ${ProfileStore.maxMottoLength} 字。',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _TextResult(_name.text.trim(), _motto.text.trim()),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 热力图卡：网格 + 图例 + 点格子的当天小结。
class _HeatCard extends ConsumerWidget {
  const _HeatCard({
    required this.overview,
    required this.today,
    required this.pickedDay,
    required this.onPick,
    required this.onClear,
  });

  final RecordsOverview overview;

  /// 今天（本地日期）。由 `recordsTodayProvider` 给，会跨零点自动更新。
  final DateTime today;

  final DateTime? pickedDay;
  final ValueChanged<DateTime> onPick;

  /// 点在"非热力图位置"（卡片空白、图例、标题）时取消选中。
  final VoidCallback onClear;

  static String _rangeLabel(int weeks) => switch (weeks) {
    13 => '近三个月',
    52 => '近一年',
    _ => '近半年',
  };

  Future<void> _pickRange(
    BuildContext context,
    WidgetRef ref,
    int current,
  ) async {
    final int? picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final int weeks in HeatWeeksController.options)
              ListTile(
                title: Text(_rangeLabel(weeks)),
                subtitle: Text('$weeks 周'),
                trailing: weeks == current
                    ? Icon(
                        Icons.check,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(weeks),
              ),
            const SizedBox(height: ShqSpace.sm),
          ],
        ),
      ),
    );
    if (picked != null) {
      await ref.read(heatWeeksProvider.notifier).set(picked);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final int weekCount = ref.watch(heatWeeksProvider);
    final List<HeatWeek> weeks = buildHeatWeeks(
      today: today,
      stats: overview.dayStats,
      weeks: weekCount,
    );
    final DateTime? picked = pickedDay;
    final DayStat? pickedStat = picked == null
        ? null
        : overview.dayStats[RecordTime.dayKey(picked)];

    return Card(
      // 外层透明手势：点标题/图例/空白都取消选中（2026-10-25 用户第 3 条）。
      // 格子自己的手势是 opaque，会先吃掉格子上的点击。
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: picked == null ? null : onClear,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.lg,
            ShqSpace.lg,
            ShqSpace.lg,
            ShqSpace.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    '作答热力图',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: ShqSpace.sm),
                  // 范围可点：13 / 26 / 52 周（用户第 8 条"显示数量上限设置"）。
                  Pressable(
                    onTap: () => _pickRange(context, ref, weekCount),
                    scale: 0.95,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: ShqSpace.xs,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            _rangeLabel(weekCount),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.expand_more,
                            size: 15,
                            color: scheme.outline,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${overview.activeDays} 天有记录',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: ShqSpace.md),
              RecordsHeatmap(
                weeks: weeks,
                today: today,
                selectedDay: picked,
                onPick: onPick,
              ),
              const SizedBox(height: ShqSpace.md),
              Row(
                children: <Widget>[
                  Text(
                    '少',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: ShqSpace.xs),
                  for (int level = 1; level <= 5; level += 1)
                    Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: ShqHeat.level(
                          level,
                          dark: theme.brightness == Brightness.dark,
                        ),
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                  const SizedBox(width: ShqSpace.xs),
                  Text(
                    '多',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      // 用相对日（今天/昨天/前天/10月24日）而不是完整日期：
                      // 2/5 栏里 "10月25日 周日 · 3 题 · 2 卷" 会被省略号截掉后半段。
                      picked == null
                          ? '点格子看当天'
                          : '${RecordTime.relativeDay(picked, today: today)} · '
                                '${pickedStat?.questions ?? 0} 题 · '
                                '${pickedStat?.workbooks ?? 0} 卷',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: picked == null
                            ? scheme.outline
                            : scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 词云卡：科目（默认）/ 题型可切。
class _CloudCard extends StatelessWidget {
  const _CloudCard({
    required this.overview,
    required this.byKind,
    required this.onToggle,
  });

  final RecordsOverview overview;
  final bool byKind;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<CloudWord> words = byKind
        ? overview.kindWords
        : overview.subjectWords;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ShqSpace.lg,
          ShqSpace.md,
          ShqSpace.lg,
          ShqSpace.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  byKind ? '题型分布' : '科目分布',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: ShqSpace.sm),
                Text(
                  '近 $kCloudDays 天',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onToggle,
                  style: TextButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                      horizontal: ShqSpace.sm,
                    ),
                    minimumSize: const Size(0, 30),
                  ),
                  icon: const Icon(Icons.swap_horiz, size: 16),
                  label: Text(byKind ? '按科目' : '按题型'),
                ),
              ],
            ),
            RecordsWordCloud(
              words: words,
              emptyLabel: byKind ? '还没有可归纳的题型' : '还没有可归纳的科目',
            ),
          ],
        ),
      ),
    );
  }
}
