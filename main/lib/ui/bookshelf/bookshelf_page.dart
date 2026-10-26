import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/favorite/favorite_store.dart';
import 'package:shuaqi/app/import/import_workbook.dart';
import 'package:shuaqi/app/storage/storage_error.dart';
import 'package:shuaqi/domain/export/export_options.dart';
import 'package:shuaqi/domain/model/import_batch.dart';
import 'package:shuaqi/domain/model/shelf_folder.dart';
import 'package:shuaqi/domain/model/tag_color.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/model/workbook_search.dart';
import 'package:shuaqi/infra/db/dao/folder_dao.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/infra/vault/vault.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/bookshelf_providers.dart';
import 'package:shuaqi/state/favorite_providers.dart';
import 'package:shuaqi/state/ui_prefs_provider.dart';
import 'package:shuaqi/ui/bookshelf/export_sheet.dart';
import 'package:shuaqi/ui/bookshelf/folder_cards.dart';
import 'package:shuaqi/ui/bookshelf/shelf_tree.dart';
import 'package:shuaqi/ui/bookshelf/tag_bookmark.dart';
import 'package:shuaqi/ui/bookshelf/workbook_export.dart';
import 'package:shuaqi/ui/bookshelf/workbook_menu_sheet.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/hex_color.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/empty_state.dart';
import 'package:shuaqi/ui/widgets/labeled_action.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';
import 'package:shuaqi/ui/widgets/soft_icon.dart';

/// 书架（T1.4 完成态）：导入 / 列表 / 最近打开 / 长按菜单 / 搜索 /
/// 下拉刷新 / 文件损坏态。
///
/// 本页是 app 的主页（外壳第一个 tab）。"我在刷哪些卷子、刷到哪了"
/// 一眼可见；其余入口（记录 / 错题 / 设置）在侧边 rail 或底部 bar。
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {

  /// 文字模式（2026-10-26 用户第 15 条）：顶栏动作旁显示功能文字。
  /// 放不下 5 个带文字的动作就退回纯图标。
  bool get _showLabels =>
      ref.watch(iconLabelsProvider) &&
      labelsFitWidth(
        width: MediaQuery.sizeOf(context).width,
        actionCount: 5,
      );
  bool _importing = false;
  String _stage = '';

  /// 批量导入的进度（2026-10-24 支持一次选多份后才有意义）。
  /// [_importDone] 已处理份数，[_importTotal] 总份数。
  int _importDone = 0;
  int _importTotal = 0;

  // ── 搜索 ─────────────────────────────────────────────────────────
  // 客户端过滤（书架上限 50 卷，成本为零）：query 只存在本页，
  // 不做成 provider——它是这一页的私有临时状态（state/ 目录的约定）。
  bool _searching = false;
  String _query = '';

  /// 当前文件夹筛选：null = 全部；'' = 未分类；其它 = 指定文件夹。
  String? _folder;

  // ── 展示 / 管理偏好（2026-10-23 书架返工）──────────────────────────
  //
  // 列表 / 大图 / 树形、卡片大小、排序都持久化到 setting 表（键名是稳定契约）。
  // 文件夹本身 v4 起落在 `folder` 表里（可嵌套、可空），不再靠 setting 存名字。
  static const String _viewKey = 'bookshelf.view';
  static const String _cardScaleKey = 'bookshelf.card_scale';
  static const String _sortKey = 'bookshelf.sort';
  static const String _treeKey = 'bookshelf.tree';
  static const String _expandedKey = 'bookshelf.expanded';

  bool _grid = false;

  /// 捏合开始时的卡片比例（连续缩放的基准）。
  double _pinchBase = 1;
  double _cardScale = 0.95;

  /// 大图卡片只有 5 级（用户 2026-10-23：级数再多也看不出差别，
  /// 而且网格列数会跳，反而没有反馈）。
  static const List<double> _cardScales = <double>[
    0.75,
    0.95,
    1.15,
    1.35,
    1.55,
  ];
  static const List<String> _cardScaleLabels = <String>[
    '小',
    '较小',
    '标准',
    '较大',
    '大',
  ];

  int get _cardLevel {
    int best = 0;
    double distance = double.infinity;
    for (int i = 0; i < _cardScales.length; i++) {
      final double d = (_cardScales[i] - _cardScale).abs();
      if (d < distance) {
        distance = d;
        best = i;
      }
    }
    return best;
  }

  BookshelfSort _sort = BookshelfSort.recent;

  /// v4 起文件夹是独立表（可嵌套）：`_folder` 存的是 **folder.id**
  /// （null = 全部，空串 = 未分类，其它 = 某个文件夹）。
  List<ShelfFolder> _folders = <ShelfFolder>[];

  /// 标签 → 颜色（`tag` 表），卡片右上角的书签用它上色。
  Map<String, String> _tagColors = <String, String>{};

  /// 树视图里展开了哪些文件夹（持久化到 `bookshelf.expanded`）。
  Set<String> _expandedFolders = <String>{};

  /// 第三种视图：Obsidian 式单栏树。
  bool _tree = false;

  // ── 多选 ─────────────────────────────────────────────────────────
  bool _selectionMode = false;
  final Set<String> _selected = <String>{};

  final TextEditingController _searchController = TextEditingController();

  SettingDao get _settings =>
      SettingDao(ref.read(appDependenciesProvider).db.raw);

  @override
  void initState() {
    super.initState();
    // ref 在 initState 可用，但让第一帧先渲染默认值，异步偏好回来再刷新。
    unawaited(_loadShelfPrefs());
    unawaited(_reloadFolders());
    unawaited(_reloadTagColors());
  }

  Future<void> _loadShelfPrefs() async {
    try {
      final SettingDao dao = _settings;
      final String? viewRaw = await dao.get(_viewKey);
      final String? treeRaw = await dao.get(_treeKey);
      final String? scaleRaw = await dao.get(_cardScaleKey);
      final String? sortRaw = await dao.get(_sortKey);
      final String? expandedRaw = await dao.get(_expandedKey);
      if (!mounted) {
        return;
      }
      setState(() {
        _grid = viewRaw == 'grid';
        _tree = treeRaw == '1';
        _expandedFolders = <String>{
          for (final Object? item in _decodeList(expandedRaw))
            if (item is String && item.isNotEmpty) item,
        };
        final double rawScale = (double.tryParse(scaleRaw ?? '') ?? 0.95).clamp(
          0.75,
          1.55,
        );
        // 2026-10-24 第二轮：卡片大小改成**双指连续缩放**，所以这里不再吸附到
        // 5 个档位（滑块仍按最近档显示，但存下来的是连续值）。
        _cardScale = rawScale;
        _sort = _sortByName(sortRaw);
      });
    } on Object {
      // 设置读失败不影响书架本身：用默认值。
    }
  }

  static List<Object?> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const <String>[];
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded;
      }
    } on FormatException {
      return const <Object?>[];
    }
    return const <Object?>[];
  }

  static BookshelfSort _sortByName(String? raw) {
    for (final BookshelfSort value in BookshelfSort.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return BookshelfSort.recent;
  }

  /// 重新读文件夹树（含把旧 `workbook.folder` 名字一次性迁成 folder 行）。
  ///
  /// 整段兜异常：文件夹只是书架的**组织方式**，读不到不该让整页打不开
  /// （退化为"全部 / 未分类"两种筛选，卷照样能刷）。
  Future<void> _reloadFolders() async {
    final FolderDao dao = ref.read(folderDaoProvider);
    bool migrated = false;
    try {
      migrated = await dao.migrateLegacyNames();
    } on Object {
      // 迁移失败不影响读：老库继续按"未分类"看。
    }
    List<ShelfFolder> folders = const <ShelfFolder>[];
    try {
      folders = await dao.list();
    } on Object {
      folders = const <ShelfFolder>[];
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _folders = folders;
      // 当前文件夹被删掉了 → 回到"全部"。
      if (_folder != null &&
          _folder!.isNotEmpty &&
          !folders.any((ShelfFolder f) => f.id == _folder)) {
        _folder = null;
      }
    });
    if (migrated) {
      ref.invalidate(bookshelfProvider);
    }
  }

  Future<void> _reloadTagColors() async {
    try {
      final Map<String, String> colors = await ref
          .read(tagDaoProvider)
          .colors();
      if (mounted) {
        setState(() => _tagColors = colors);
      }
    } on Object {
      // 没有颜色表也能用：书签退回中性色。
    }
  }

  Future<void> _saveTree() async {
    try {
      await _settings.put(_treeKey, _tree ? '1' : '0');
    } on Object {
      // 忽略
    }
  }

  Future<void> _saveExpanded() async {
    try {
      await _settings.put(
        _expandedKey,
        jsonEncode(_expandedFolders.toList(growable: false)),
      );
    } on Object {
      // 忽略
    }
  }

  Future<void> _saveView() async {
    try {
      await _settings.put(_viewKey, _grid ? 'grid' : 'list');
    } on Object {
      // 忽略
    }
  }

  Future<void> _saveScale() async {
    try {
      await _settings.put(_cardScaleKey, _cardScale.toStringAsFixed(2));
    } on Object {
      // 忽略
    }
  }

  Future<void> _saveSort() async {
    try {
      await _settings.put(_sortKey, _sort.name);
    } on Object {
      // 忽略
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _pickAndImport() async {
    if (_importing) {
      return;
    }
    List<PlatformFile> picked = const <PlatformFile>[];
    try {
      // file_picker 13 起是静态方法，直接返回 List<PlatformFile>（不再有 FilePickerResult）。
      // Android 端 `pickFiles` 走 `allowMultiple: true`（`pickFile` 才是单选），
      // 所以这里一次可以选多份——用户诉求 2026-10-24。
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['pdf'],
      );
    } on Object catch (error) {
      _toast('打开文件选择器失败：$error');
      return;
    }
    // 只要本地真实路径：有些平台（如 SAF）给的是 content:// URI，
    // 那样没法直接 File(path) 复制进 Vault。
    final List<File> files = <File>[
      for (final PlatformFile file in picked)
        if (file.path != null && file.path!.isNotEmpty) File(file.path!),
    ];
    if (files.isEmpty) {
      return; // 用户取消
    }

    setState(() {
      _importing = true;
      _stage = '准备中';
      _importTotal = files.length;
      _importDone = 0;
    });
    try {
      final ImportBatchResult result = await _importAll(files);
      if (!mounted) {
        return;
      }
      _toast(importSummaryMessage(result));
      ref.invalidate(bookshelfProvider);
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
          _stage = '';
          _importTotal = 0;
          _importDone = 0;
        });
      }
    }
  }

  /// 逐份导入。**串行**而不是并行：
  ///
  /// 每份导入要算 sha1、复制文件、读页数、生成缩略图（pdfium 解码 + PNG 编码），
  /// 并行做会让 CPU 与内存峰值翻几倍，几十页的卷很容易 OOM。
  /// 串行的代价只是慢一点，而导入本来就是后台等待的场景。
  ///
  /// **一份失败不打断其余**：用户选了 5 份、其中 1 份是加密 PDF，
  /// 不该因为这一份把另外 4 份也废掉。
  Future<ImportBatchResult> _importAll(List<File> files) async {
    final List<ImportedWorkbook> imported = <ImportedWorkbook>[];
    final List<String> deduplicated = <String>[];
    final List<String> failures = <String>[];
    for (final File file in files) {
      if (!mounted) {
        break;
      }
      setState(() {
        _importDone++;
        _stage = '导入中';
      });
      try {
        final ImportOutcome outcome = await ref
            .read(workbookImporterProvider)
            .run(
              file,
              onProgress: (String stage) {
                if (mounted) {
                  setState(() {
                    _stage = stage;
                  });
                }
              },
            );
        if (outcome.deduped) {
          deduplicated.add(outcome.workbook.title);
        } else {
          imported.add(
            ImportedWorkbook(
              title: outcome.workbook.title,
              pageCount: outcome.workbook.pageCount,
              thumbCount: outcome.thumbCount,
            ),
          );
        }
      } on ImportException catch (error) {
        failures.add('${_fileNameOf(file.path)}：${error.message}');
      } on Object catch (error) {
        failures.add('${_fileNameOf(file.path)}：$error');
      }
    }
    return ImportBatchResult(
      imported: imported,
      deduplicated: deduplicated,
      failures: failures,
    );
  }

  /// 文件名（不含目录与扩展名），用于失败提示里说清是哪一份。
  static String _fileNameOf(String path) {
    final String name = path.split(RegExp(r'[/\\]')).last;
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 导入中 FAB 上的文案。
  ///
  /// 多份时要能看出**进度**（"导入 2/5"）——单看"计算指纹"这种阶段名，
  /// 用户不知道还要等几份。阶段名只在一份时才有意义（那时它就是全部信息）。
  String get _importLabel {
    if (_importTotal > 1) {
      return '导入 $_importDone/$_importTotal';
    }
    return _stage;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  /// 导出 PDF（2026-10-25）。
  ///
  /// 编排顺序：选组合 → 进度弹窗 → 生成字节 → 交给系统落进「下载」。
  /// 字节怎么来（渲染、PDF 语法）在 `workbook_export.dart` / `app/export`，
  /// 这里只负责把三段串起来，并把失败翻成一句人话。
  Future<void> _export(Workbook workbook) async {
    final ExportRequest? request = await showExportOptionsSheet(
      context,
      workbook: workbook,
    );
    if (request == null || !mounted) {
      return;
    }
    final ExportOptions options = request.options;
    final ValueNotifier<ExportProgress> progress =
        ValueNotifier<ExportProgress>(const ExportProgress('准备中'));
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) =>
            ExportProgressDialog(title: workbook.title, progress: progress),
      ),
    );
    try {
      final WorkbookExporter exporter = WorkbookExporter(
        deps: ref.read(appDependenciesProvider),
        workbook: workbook,
      );
      final Uint8List bytes = await exporter.buildPdf(
        options,
        onProgress: (ExportProgress value) => progress.value = value,
      );
      final String name = exportFileName(
        workbook.title,
        DateTime.now(),
        options: options,
        customName: request.fileName,
      );
      final String path = await savePdfToDownloads(bytes, name);
      if (!mounted) {
        return;
      }
      Navigator.of(context, rootNavigator: true).pop();
      _toast(
        path.isEmpty
            ? '已导出 $name'
            : '已导出到「${path.toLowerCase().contains('download') ? '下载/SHUAQI' : '应用目录'}」：$name',
      );
    } on Object catch (error) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _toast(storageAwareMessage('导出', error));
      }
    } finally {
      // 弹窗还在做退场动画时不能 dispose 监听对象；延后一点再回收。
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 600),
          progress.dispose,
        ),
      );
    }
  }

  // ── 长按菜单的三个动作 ────────────────────────────────────────────

  Future<void> _rename(Workbook workbook) async {
    final String? title = await showRenameDialog(
      context,
      initialTitle: workbook.title,
    );
    if (title == null || !mounted) {
      return;
    }
    await ref.read(workbookDaoProvider).rename(workbook.id, title);
    // 与收藏夹双向同步：把收藏快照上的卷名一起改掉（卡片/看题页立刻跟上）。
    try {
      await ref.read(favoriteStoreProvider).renameWorkbook(workbook.id, title);
      ref.invalidate(favoritesProvider);
    } on Object {
      // 同步失败不影响书架改名本身。
    }
    ref.invalidate(bookshelfProvider);
  }

  Future<void> _delete(Workbook workbook) async {
    // 删卷前先数一数收藏：库里删了不影响收藏（快照独立），但用户要知道。
    int favoriteCount = 0;
    try {
      favoriteCount = await ref
          .read(favoriteStoreProvider)
          .countOfWorkbook(workbook.id);
    } on Object {
      // 数不出来就按 0 处理，不阻断删除。
    }
    if (!mounted) {
      return;
    }
    final bool confirmed = await showDeleteConfirmDialog(
      context,
      title: workbook.title,
      favoriteCount: favoriteCount,
    );
    if (!confirmed || !mounted) {
      return;
    }
    // 先库后目录：库里没了，目录就算残留也会被下次启动的 sweepOrphans 收掉；
    // 反过来（目录没了、库还在）会留下一条永远打不开的幽灵记录。
    await ref.read(workbookDaoProvider).delete(workbook.id);
    await ref.read(vaultProvider).deleteWorkbook(workbook.id);
    if (favoriteCount > 0) {
      // 收藏不设外键，卷删了行还在：标记来源已删，看题页走快照兜底。
      try {
        await ref.read(favoriteStoreProvider).markSourceDeleted(workbook.id);
        ref.invalidate(favoritesProvider);
      } on Object {
        // 标记失败只影响「原卷已删」提示，不影响收藏本身。
      }
    }
    ref.invalidate(bookshelfProvider);
    _toast(
      favoriteCount > 0
          ? '已删除《${workbook.title}》· 收藏保留 $favoriteCount 题'
          : '已删除《${workbook.title}》',
    );
  }

  void _openMenu(Workbook workbook) {
    unawaited(
      showWorkbookMenu(
        context,
        workbook: workbook,
        onRename: () => unawaited(_rename(workbook)),
        onEditTags: () => unawaited(_editTags(workbook)),
        onMoveToFolder: () => unawaited(_moveToFolder(workbook)),
        onDelete: () => unawaited(_delete(workbook)),
        onExport: () => unawaited(_export(workbook)),
      ),
    );
  }

  // ── 文件夹与标签（2026-10-23 书架管理）───────────────────────────────

  /// 编辑标签 —— 书签配色也在里面（2026-10-24 用户口径：改标签和挑颜色是一件事）。
  ///
  /// 长按卡片右上角的书签也走这里：那枚书签就是"这个标签长什么样"，
  /// 点/长按它的意图和「编辑标签」完全一样，不该再分出第二个弹窗。
  Future<void> _editTags(Workbook workbook) async {
    final List<String>? tags = await showTagsDialog(
      context,
      initial: workbook.tags,
      colors: _tagColors,
      onPickColor: (String tag, String hex) =>
          unawaited(_setTagColor(tag, hex)),
    );
    if (tags == null || !mounted) {
      return;
    }
    await ref
        .read(workbookDaoProvider)
        .setTags(workbook.id, WorkbookTags.encode(tags));
    ref.invalidate(bookshelfProvider);
    if (mounted) {
      _toast(tags.isEmpty ? '已清除标签' : '标签：${tags.join(' / ')}');
    }
  }

  /// 文件夹 id → 名字（显示用）。
  String _folderNameOf(String id) {
    for (final ShelfFolder folder in _folders) {
      if (folder.id == id) {
        return folder.name;
      }
    }
    return '';
  }

  ShelfFolder? _folderOf(String id) {
    for (final ShelfFolder folder in _folders) {
      if (folder.id == id) {
        return folder;
      }
    }
    return null;
  }

  /// 当前层的子文件夹（"全部 / 未分类"都按顶层算）。
  List<ShelfFolder> get _childFolders =>
      childFolders(_folders, (_folder ?? '').isEmpty ? '' : _folder!);

  /// 从根到当前的路径（面包屑）。
  List<ShelfFolder> get _path => (_folder ?? '').isEmpty
      ? const <ShelfFolder>[]
      : folderPath(_folders, _folder!);

  // ── 树视图里长按拖动改归属（2026-10-24 用户第 4 条）──────────────────

  /// 落点要展开：不然拖完那卷就"消失"了（它其实进了折叠的文件夹）。
  void _revealFolder(String folderId) {
    setState(() => _expandedFolders.add(folderId));
    unawaited(_saveExpanded());
  }

  Future<void> _moveWorkbookTo(Workbook workbook, String folderId) async {
    if (workbook.folderId == folderId) {
      return;
    }
    await ref.read(workbookDaoProvider).setFolderId(workbook.id, folderId);
    ref.invalidate(bookshelfProvider);
    if (!mounted) {
      return;
    }
    _revealFolder(folderId);
    _toast(
      folderId.isEmpty
          ? '已把《${workbook.title}》移到未分类'
          : '已把《${workbook.title}》放进「${_folderNameOf(folderId)}」',
    );
  }

  Future<void> _moveFolderTo(String folderId, String parentId) async {
    final ShelfFolder? folder = _folderOf(folderId);
    if (folder == null || folder.parentId == parentId) {
      return;
    }
    // 树里已经挡了一道，这里再挡一次：**数据层不能信 UI 的挡法**。
    // 拖进自己的子孙会让 folder 表成环，之后任何一次遍历都会死循环。
    if (parentId.isNotEmpty &&
        folderSubtreeIds(_folders, folderId).contains(parentId)) {
      _toast('「${folder.name}」不能放进它自己里面');
      return;
    }
    await ref.read(folderDaoProvider).setParent(folderId, parentId);
    await _reloadFolders();
    if (!mounted) {
      return;
    }
    _revealFolder(parentId);
    _toast(
      parentId.isEmpty
          ? '已把「${folder.name}」移到顶层'
          : '已把「${folder.name}」放进「${_folderNameOf(parentId)}」',
    );
  }

  Future<void> _moveToFolder(Workbook workbook) async {
    final String? folderId = await showFolderPicker(
      context,
      folders: _folders,
      currentId: workbook.folderId,
    );
    if (folderId == null || !mounted || folderId == workbook.folderId) {
      return;
    }
    await ref.read(workbookDaoProvider).setFolderId(workbook.id, folderId);
    ref.invalidate(bookshelfProvider);
    if (mounted) {
      _toast(folderId.isEmpty ? '已移到未分类' : '已移到「${_folderNameOf(folderId)}」');
    }
  }

  void _selectFolder(String? folderId) {
    setState(() => _folder = folderId);
  }

  /// 树视图里展开 / 收起一个文件夹（展开状态跨会话保留）。
  void _toggleFolderExpanded(String id) {
    setState(() {
      if (!_expandedFolders.add(id)) {
        _expandedFolders.remove(id);
      }
    });
    unawaited(_saveExpanded());
  }

  /// 「选择文件」：把**已经导入**的卷批量放进当前文件夹。
  ///
  /// 为什么不复用「导入 PDF」：导入会新建一条卷记录、并在「全部」里再出现一次；
  /// 用户新建文件夹后真正想做的，往往是把已有（尤其未分类）的卷收进去。
  Future<void> _addExistingToFolder(List<Workbook> items) async {
    final String? folder = _folder;
    if (folder == null || folder.isEmpty) {
      return;
    }
    final List<Workbook> candidates = <Workbook>[
      for (final Workbook workbook in items)
        if (workbook.folderId != folder) workbook,
    ];
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String>? picked = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // App 主题把 bottom sheet 背景统一设成透明（由内容自己画），这份内容
      // 没有自绘容器，必须在这里补背景，否则书架会从浮层后面透出来。
      backgroundColor: scheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
      ),
      builder: (BuildContext sheetContext) => _AddToFolderSheet(
        folder: _folderNameOf(folder),
        candidates: candidates,
        onImport: () {
          Navigator.of(sheetContext).pop();
          unawaited(_pickAndImport());
        },
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) {
      return;
    }
    final WorkbookDao dao = ref.read(workbookDaoProvider);
    for (final String id in picked) {
      await dao.setFolderId(id, folder);
    }
    ref.invalidate(bookshelfProvider);
    if (mounted) {
      _toast(
        picked.length == 1
            ? '已加入「${_folderNameOf(folder)}」'
            : '已把 ${picked.length} 卷加入「${_folderNameOf(folder)}」',
      );
    }
  }

  // ── 文件夹管理（新建 / 重命名 / 颜色 / 删除）─────────────────────

  // 文件夹与标签共用一份色板（[kTagPalette]，纯 Dart 里定义）：
  // 视觉上"蓝色文件夹 / 蓝色标签"是同一套语言，分开定义迟早会长歪。

  /// [parentId] 为空 = 建在"当前文件夹"里面（在"全部/未分类"下就是顶层）。
  Future<void> _createFolder(List<Workbook> items, {String? parentId}) async {
    final String? name = await showRenameDialog(
      context,
      initialTitle: '',
      dialogTitle: '新建文件夹',
      fieldLabel: '文件夹名',
    );
    final String trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) {
      return;
    }
    parentId ??= _folder ?? '';
    final bool duplicate = _folders.any(
      (ShelfFolder folder) =>
          folder.parentId == parentId && folder.name == trimmed,
    );
    if (duplicate) {
      _toast('这里已经有「$trimmed」了');
      return;
    }
    final ShelfFolder created = await ref
        .read(folderDaoProvider)
        .create(name: trimmed, parentId: parentId);
    await _reloadFolders();
    if (mounted) {
      setState(() => _folder = created.id);
      _toast('已新建「$trimmed」，可以把卷子移进来');
    }
  }

  Future<void> _showFolderMenu(ShelfFolder folder) async {
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text('文件夹「${folder.name}」'),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('rename'),
            child: const Row(
              children: <Widget>[
                Icon(Icons.drive_file_rename_outline, size: 18),
                SizedBox(width: ShqSpace.sm),
                Text('重命名'),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('color'),
            child: const Row(
              children: <Widget>[
                Icon(Icons.palette_outlined, size: 18),
                SizedBox(width: ShqSpace.sm),
                Text('颜色'),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('newChild'),
            child: const Row(
              children: <Widget>[
                Icon(Icons.create_new_folder_outlined, size: 18),
                SizedBox(width: ShqSpace.sm),
                Text('在里面新建文件夹'),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('delete'),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.folder_delete_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: ShqSpace.sm),
                Text(
                  '删除文件夹',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case 'rename':
        await _renameFolder(folder);
      case 'color':
        await _pickFolderColor(folder);
      case 'newChild':
        await _createFolder(<Workbook>[], parentId: folder.id);
      case 'delete':
        await _deleteFolder(folder);
    }
  }

  Future<void> _pickFolderColor(ShelfFolder folder) async {
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text('「${folder.name}」的颜色'),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ShqSpace.lg,
              vertical: ShqSpace.sm,
            ),
            child: Wrap(
              spacing: ShqSpace.sm,
              runSpacing: ShqSpace.sm,
              children: <Widget>[
                for (final String hex in kTagPalette)
                  InkWell(
                    onTap: () => Navigator.of(context).pop(hex),
                    borderRadius: BorderRadius.circular(ShqRadius.pill),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: shqHexColor(hex),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: folder.color.toLowerCase() == hex.toLowerCase()
                              ? Theme.of(context).colorScheme.onSurface
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: folder.color.toLowerCase() == hex.toLowerCase()
                          ? const Icon(
                              Icons.check,
                              size: 16,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    await ref.read(folderDaoProvider).setColor(folder.id, picked);
    await _reloadFolders();
  }

  Future<void> _deleteFolder(ShelfFolder folder) async {
    final int count = (ref.read(bookshelfProvider).value ?? const <Workbook>[])
        .where((Workbook workbook) => workbook.folderId == folder.id)
        .length;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('删除「${folder.name}」？'),
        content: Text(
          count == 0
              ? '子文件夹会一起删掉，里面的卷变成未分类。卷子本身不会被删。'
              : '里面 $count 卷会变成未分类（不会被删），子文件夹一起删掉。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await ref
        .read(folderDaoProvider)
        .delete(folder.id, subtreeIds: folderSubtreeIds(_folders, folder.id));
    await _reloadFolders();
    ref.invalidate(bookshelfProvider);
    if (mounted) {
      setState(() {
        if (_folder == folder.id) {
          _folder = folder.parentId.isEmpty ? null : folder.parentId;
        }
      });
      _toast('已删除「${folder.name}」');
    }
  }

  // ── 多选与批量操作 ────────────────────────────────────────────────

  void _enterSelection() {
    setState(() {
      _selectionMode = true;
      _selected.clear();
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.add(id)) {
        _selected.remove(id);
      }
    });
  }

  void _selectAll(List<Workbook> visible) {
    setState(() {
      _selected
        ..clear()
        ..addAll(visible.map((Workbook w) => w.id));
    });
  }

  List<Workbook> _selectedWorkbooks(List<Workbook> items) {
    return items
        .where((Workbook w) => _selected.contains(w.id))
        .toList(growable: false);
  }

  Future<void> _batchMove(List<Workbook> items) async {
    if (_selected.isEmpty) {
      return;
    }
    final String? folderId = await showFolderPicker(
      context,
      folders: _folders,
      currentId: '',
    );
    if (folderId == null || !mounted) {
      return;
    }
    final WorkbookDao dao = ref.read(workbookDaoProvider);
    for (final Workbook wb in _selectedWorkbooks(items)) {
      await dao.setFolderId(wb.id, folderId);
    }
    final int count = _selected.length;
    ref.invalidate(bookshelfProvider);
    if (!mounted) {
      return;
    }
    _exitSelection();
    _toast(
      folderId.isEmpty
          ? '已把 $count 卷移到未分类'
          : '已把 $count 卷移到「${_folderNameOf(folderId)}」',
    );
  }

  Future<void> _batchTags(List<Workbook> items) async {
    if (_selected.isEmpty) {
      return;
    }
    final List<String>? tags = await showTagsDialog(
      context,
      initial: const <String>[],
    );
    if (tags == null || !mounted) {
      return;
    }
    final WorkbookDao dao = ref.read(workbookDaoProvider);
    for (final Workbook wb in _selectedWorkbooks(items)) {
      await dao.setTags(wb.id, WorkbookTags.encode(tags));
    }
    final int count = _selected.length;
    ref.invalidate(bookshelfProvider);
    if (!mounted) {
      return;
    }
    _exitSelection();
    _toast(tags.isEmpty ? '已清除 $count 卷的标签' : '已给 $count 卷设置标签');
  }

  Future<void> _batchDelete(List<Workbook> items) async {
    if (_selected.isEmpty) {
      return;
    }
    final List<Workbook> deleting = _selectedWorkbooks(items);
    final int count = deleting.length;
    // 和单卷删除保持一致：先把这些卷的收藏数算出来，删卷后收藏仍保留。
    int favoriteCount = 0;
    try {
      final FavoriteStore store = ref.read(favoriteStoreProvider);
      for (final Workbook workbook in deleting) {
        favoriteCount += await store.countOfWorkbook(workbook.id);
      }
    } on Object {
      // 数不出来不影响删除，只是少一句提示。
    }
    if (!mounted) {
      return;
    }
    final bool ok =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: Text('删除 $count 卷？'),
            content: Text(
              '删除后无法恢复。PDF、缩略图、笔迹与识别记录都会一起删除。'
              '${favoriteCount > 0 ? '\n\n这些卷的 $favoriteCount 道收藏会保留，只标记「原卷已删」。' : ''}',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) {
      return;
    }
    final WorkbookDao dao = ref.read(workbookDaoProvider);
    final Vault vault = ref.read(vaultProvider);
    final FavoriteStore favoriteStore = ref.read(favoriteStoreProvider);
    for (final Workbook wb in deleting) {
      await dao.delete(wb.id);
      await vault.deleteWorkbook(wb.id);
      // 收藏不设外键：批量删卷也要逐卷标记来源已删，
      // 否则收藏夹会显示成「原卷还在」，看题页的回看出处会点进空卷。
      try {
        await favoriteStore.markSourceDeleted(wb.id);
      } on Object {
        // 标记失败只影响提示，不影响删除本身。
      }
    }
    ref.invalidate(favoritesProvider);
    ref.invalidate(bookshelfProvider);
    if (!mounted) {
      return;
    }
    _exitSelection();
    _toast('已删除 $count 卷');
  }

  /// 重命名文件夹（批量改它下面所有卷的归属）。
  ///
  /// 之前 DAO 里有 `renameFolder` 但没有入口（027 的遗留项）。入口放在
  /// 文件夹 chip 的长按上：用户已经在看这个文件夹，改名是这里最自然的动作。
  Future<void> _renameFolder(ShelfFolder folder) async {
    final String? next = await showRenameDialog(
      context,
      initialTitle: folder.name,
      dialogTitle: '重命名文件夹',
      fieldLabel: '文件夹名',
    );
    final String trimmed = next?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == folder.name || !mounted) {
      return;
    }
    await ref.read(folderDaoProvider).rename(folder.id, trimmed);
    await _reloadFolders();
    if (mounted) {
      _toast('文件夹已重命名为「$trimmed」');
    }
  }

  // ── 搜索 ─────────────────────────────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      _query = '';
      _searchController.clear();
    });
  }

  // ── 下拉刷新 ─────────────────────────────────────────────────────

  Future<void> _refresh() async {
    ref.invalidate(bookshelfProvider);
    // 等新 future 真正完成，RefreshIndicator 的转圈才会在数据回来后收
    await ref.read(bookshelfProvider.future);
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Workbook>> books = ref.watch(bookshelfProvider);
    final List<Workbook> all = books.value ?? const <Workbook>[];
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) {
          _exitSelection();
        }
      },
      child: Scaffold(
        appBar: _selectionMode ? _selectionAppBar(all) : _normalAppBar(all),
        body: books.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object error, StackTrace stack) => _ErrorView(
            message: '$error',
            onRetry: () => ref.invalidate(bookshelfProvider),
          ),
          data: (List<Workbook> items) {
            if (items.isEmpty) {
              return _EmptyView(onImport: _pickAndImport);
            }
            final List<Workbook> visible = _visibleOf(items);
            // 树形视图（需求 9）：单栏纯文本树，末端是文件夹，PDF 只占一行文件名。
            // 它自带导航（缩进 + 展开），所以不再叠横向的文件夹条。
            if (_tree) {
              return ShelfTree(
                folders: _folders,
                expanded: _expandedFolders,
                workbooks: items,
                query: _query,
                selectedFolderId: _folder,
                selecting: _selectionMode,
                selectedIds: _selected,
                onToggleExpand: _toggleFolderExpanded,
                onOpenWorkbook: _open,
                onWorkbookMenu: _openMenu,
                onToggleSelected: _toggleSelected,
                onFolderMenu: (ShelfFolder folder) =>
                    unawaited(_showFolderMenu(folder)),
                onOpenFolder: (String id) {
                  setState(() {
                    _folder = id;
                    _tree = false;
                  });
                  unawaited(_saveTree());
                },
                onNewFolder: () =>
                    unawaited(_createFolder(items, parentId: '')),
                onClearQuery: () {
                  setState(() {
                    _query = '';
                    _searchController.clear();
                  });
                },
                onMoveWorkbook: (Workbook workbook, String folderId) =>
                    unawaited(_moveWorkbookTo(workbook, folderId)),
                onMoveFolder: (String folderId, String parentId) =>
                    unawaited(_moveFolderTo(folderId, parentId)),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 文件夹筛选条：全部 / 未分类 / 各文件夹 / 新建。
                // 只要书架上有卷就显示 —— 没有它，用户不知道"移动/标签"这套功能存在。
                _FolderBar(
                  folders: _childFolders,
                  foldersWithChildren: <String>{
                    for (final ShelfFolder folder in _folders)
                      folder.parentId,
                  },
                  path: _path,
                  selectedId: _folder,
                  onSelected: _selectFolder,
                  onManageFolder: (ShelfFolder folder) =>
                      unawaited(_showFolderMenu(folder)),
                  onCreateFolder: () => unawaited(_createFolder(items)),
                  unfiledCount: items
                      .where((Workbook w) => w.folderId.isEmpty)
                      .length,
                  total: items.length,
                ),
                // 进了具体文件夹，就给一个"从已导入的卷里挑"的入口。
                // 它和右下角「导入 PDF」是两件事：那个把外部 PDF 变成新卷，
                // 这个只归档已有卷（尤其是刚导入、还在未分类里的）。
                if (_folder != null && _folder!.isNotEmpty)
                  _FolderTargetBar(
                    folder: _folderNameOf(_folder!),
                    count: items
                        .where((Workbook w) => w.folderId == _folder)
                        .length,
                    onSelectFiles: () => unawaited(_addExistingToFolder(items)),
                  ),
                // 子文件夹卡片（2026-10-26 用户第 10 条）：进了外层文件夹后，
                // 里面的子文件夹必须看得见（否则那个文件夹看着像空的）。
                // 搜索中 / 多选时不出现：它们不是搜索结果，也不是可选对象。
                if (_folder != null &&
                    _folder!.isNotEmpty &&
                    _childFolders.isNotEmpty &&
                    _query.isEmpty &&
                    !_selectionMode) ...<Widget>[
                  FolderCards(
                    folders: _childFolders,
                    workbooks: items,
                    grid: _grid && !_tree,
                    onOpen: (String id) => setState(() => _folder = id),
                  ),
                  const SizedBox(height: ShqSpace.sm),
                ],
                Expanded(
                  child: visible.isEmpty
                      ? EmptyState(
                          icon: Icons.search_off_outlined,
                          title: _query.isNotEmpty
                              ? '这里没有卷子'
                              : (_folder != null && _folder!.isNotEmpty
                                    ? '「${_folderNameOf(_folder!)}」还是空的'
                                    : '这里没有卷子'),
                          message: _query.isNotEmpty
                              ? '没有匹配「$_query」的卷子，换个词试试'
                              : (_folder != null && _folder!.isNotEmpty
                                    ? '从已导入的卷里挑几份加进来，或点右下角「导入 PDF」'
                                    : '这个文件夹还是空的，可以把卷子移进来'),
                          actionLabel: _query.isNotEmpty
                              ? '清除筛选'
                              : (_folder != null && _folder!.isNotEmpty
                                    ? '选择文件'
                                    : '清除筛选'),
                          actionIcon: _query.isNotEmpty
                              ? Icons.filter_alt_off_outlined
                              : (_folder != null && _folder!.isNotEmpty
                                    ? Icons.playlist_add
                                    : Icons.filter_alt_off_outlined),
                          onAction: () {
                            if (_folder != null &&
                                _folder!.isNotEmpty &&
                                _query.isEmpty) {
                              unawaited(_addExistingToFolder(items));
                              return;
                            }
                            setState(() {
                              _query = '';
                              _searchController.clear();
                              _folder = null;
                            });
                          },
                        )
                      : RefreshIndicator(
                          onRefresh: _refresh,
                          child: _content(visible),
                        ),
                ),
              ],
            );
          },
        ),
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton.extended(
                onPressed: _importing
                    ? null
                    : () => unawaited(_pickAndImport()),
                icon: _importing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: Text(_importing ? _importLabel : '导入 PDF'),
              ),
      ),
    );
  }

  /// 当前筛选 + 排序后的可见卷（顶栏"全选"和列表共用同一份口径）。
  /// 当前可见的卷：先按文件夹（id）过滤，再按搜索词，最后排序。
  ///
  /// v4 起 folder 存的是 id：null = 全部，空串 = 未分类，其它 = 某个文件夹。
  List<Workbook> _visibleOf(List<Workbook> items) {
    final String? folderId = _folder;
    final List<Workbook> scoped = folderId == null
        ? items
        : <Workbook>[
            for (final Workbook workbook in items)
              if (workbook.folderId == folderId) workbook,
          ];
    return sortWorkbooks(filterByQuery(scoped, _query), _sort);
  }

  /// 顶栏"视图"按钮的图标跟着当前视图走（列表 / 大图 / 树形三种）。
  IconData get _viewIcon {
    if (_tree) {
      return Icons.account_tree_outlined;
    }
    return _grid ? Icons.grid_view : Icons.view_list;
  }

  /// 某个文件夹的颜色（用户设的；没设就退回主题主色）。
  Color _folderColorOf(String folderId) {
    final ShelfFolder? folder = _folderOf(folderId);
    if (folder == null || folder.color.isEmpty) {
      return Theme.of(context).colorScheme.primary;
    }
    return shqHexColor(folder.color);
  }

  /// 标签的颜色：用户设过就用它，否则按名字稳定地落一个色（[defaultTagHex]）。
  ///
  /// 空串 = 用户选了"默认"，等价于没设过 —— 必须一起处理，否则书签会变主题色。
  Color _tagColorOf(String tag) {
    final String? hex = _tagColors[tag];
    return shqHexColor((hex == null || hex.isEmpty) ? defaultTagHex(tag) : hex);
  }

  /// 卡片上的文件夹名：`folder_id` 优先，老数据的 `folder` 名字兜底。
  String _folderLabelOf(Workbook workbook) {
    final String byId = _folderNameOf(workbook.folderId);
    return byId.isNotEmpty ? byId : workbook.folder;
  }

  Future<void> _setTagColor(String tag, String hex) async {
    try {
      await ref.read(tagDaoProvider).setColor(tag, hex);
      await _reloadTagColors();
    } on Object {
      if (mounted) {
        _toast('标签颜色没保存成功');
      }
    }
  }

  AppBar _normalAppBar(List<Workbook> all) {
    return AppBar(
      title: _searching ? _searchField() : const Text('书架'),
      actions: <Widget>[
        LabeledAction(
          icon: _searching ? Icons.close : Icons.search,
          label: '搜索',
          tooltip: _searching ? '退出搜索' : '搜索',
          showLabel: _showLabels,
          onPressed: _toggleSearch,
        ),
        LabeledAction(
          icon: Icons.checklist_outlined,
          label: '多选',
          tooltip: '多选',
          showLabel: _showLabels,
          onPressed: all.isEmpty ? null : _enterSelection,
        ),
        PopupMenuButton<BookshelfSort>(
          tooltip: '排序',
          child: LabeledActionLabel(
            icon: Icons.sort,
            label: '排序',
            showLabel: _showLabels,
          ),
          onSelected: (BookshelfSort value) {
            setState(() => _sort = value);
            unawaited(_saveSort());
          },
          itemBuilder: (BuildContext context) =>
              <PopupMenuEntry<BookshelfSort>>[
                CheckedPopupMenuItem<BookshelfSort>(
                  value: BookshelfSort.recent,
                  checked: _sort == BookshelfSort.recent,
                  child: const Text('最近打开'),
                ),
                CheckedPopupMenuItem<BookshelfSort>(
                  value: BookshelfSort.title,
                  checked: _sort == BookshelfSort.title,
                  child: const Text('标题'),
                ),
                CheckedPopupMenuItem<BookshelfSort>(
                  value: BookshelfSort.pages,
                  checked: _sort == BookshelfSort.pages,
                  child: const Text('页数'),
                ),
              ],
        ),
        // 三种视图的切换就在这里（2026-10-24 用户第 9 条：树形入口放主页顶栏）。
        PopupMenuButton<String>(
          tooltip: '视图',
          child: LabeledActionLabel(
            icon: _viewIcon,
            label: '视图',
            showLabel: _showLabels,
          ),
          onSelected: (String value) {
            switch (value) {
              case 'list':
              case 'grid':
                setState(() {
                  _grid = value == 'grid';
                  _tree = false;
                });
                unawaited(_saveView());
                unawaited(_saveTree());
              case 'tree':
                setState(() => _tree = true);
                unawaited(_saveTree());
              case 'size':
                unawaited(_showCardSizeSheet());
            }
          },
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            CheckedPopupMenuItem<String>(
              value: 'list',
              checked: !_grid && !_tree,
              child: const Text('列表'),
            ),
            CheckedPopupMenuItem<String>(
              value: 'grid',
              checked: _grid && !_tree,
              child: const Text('大图'),
            ),
            CheckedPopupMenuItem<String>(
              value: 'tree',
              checked: _tree,
              child: const Text('树形'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'size',
              child: Row(
                children: <Widget>[
                  Icon(Icons.tune, size: 18),
                  SizedBox(width: ShqSpace.sm),
                  Text('卡片大小…'),
                ],
              ),
            ),
          ],
        ),
        LabeledAction(
          icon: Icons.refresh,
          label: '刷新',
          tooltip: '刷新',
          showLabel: _showLabels,
          onPressed: () => unawaited(_refresh()),
        ),
      ],
    );
  }

  AppBar _selectionAppBar(List<Workbook> all) {
    final List<Workbook> visible = _visibleOf(all);
    final bool has = _selected.isNotEmpty;
    return AppBar(
      leading: IconButton(
        tooltip: '退出多选',
        onPressed: _exitSelection,
        icon: const Icon(Icons.close),
      ),
      title: Text('已选 ${_selected.length}'),
      actions: <Widget>[
        IconButton(
          tooltip: '全选当前列表',
          onPressed: visible.isEmpty ? null : () => _selectAll(visible),
          icon: const Icon(Icons.select_all),
        ),
        IconButton(
          tooltip: '移动到文件夹',
          onPressed: has ? () => unawaited(_batchMove(all)) : null,
          icon: const Icon(Icons.drive_file_move_outline),
        ),
        IconButton(
          tooltip: '设置标签',
          onPressed: has ? () => unawaited(_batchTags(all)) : null,
          icon: const Icon(Icons.label_outline),
        ),
        IconButton(
          tooltip: '删除',
          onPressed: has ? () => unawaited(_batchDelete(all)) : null,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }

  Widget _searchField() {
    return TextField(
      controller: _searchController,
      autofocus: true,
      style: Theme.of(context).textTheme.bodyMedium,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '搜索标题 / 标签 / 文件夹',
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 20),
        // 有内容才出现清除钮：空搜索框上多一个叉是噪音。
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: '清除',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
              ),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ShqRadius.pill),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ShqRadius.pill),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ShqRadius.pill),
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.primary
                .withValues(alpha: 0.45),
          ),
        ),
      ),
      onChanged: (String value) => setState(() => _query = value),
    );
  }

  Future<void> _showCardSizeSheet() async {
    int draftLevel = _cardLevel;
    final ColorScheme sheetScheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // 与「选择文件」同一原因：内容没有自绘背景，必须由路由给一层实底。
      backgroundColor: sheetScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheet) {
            final ColorScheme scheme = Theme.of(context).colorScheme;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.lg,
                  0,
                  ShqSpace.lg,
                  ShqSpace.lg,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      '卡片大小',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: ShqSpace.xs),
                    Text(
                      '大图模式 5 级；拖动时首页实时变化，列表模式不受影响。',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: ShqSpace.sm),
                    Row(
                      children: <Widget>[
                        const Icon(Icons.photo_size_select_small, size: 18),
                        Expanded(
                          child: Slider(
                            value: draftLevel.toDouble(),
                            min: 0,
                            max: 4,
                            divisions: 4,
                            label: _cardScaleLabels[draftLevel],
                            onChanged: (double value) {
                              final int level = value.round();
                              setSheet(() => draftLevel = level);
                              setState(() => _cardScale = _cardScales[level]);
                            },
                            onChangeEnd: (double value) {
                              unawaited(_saveScale());
                            },
                          ),
                        ),
                        const Icon(Icons.photo_size_select_large, size: 18),
                      ],
                    ),
                    Row(
                      children: <Widget>[
                        for (int i = 0; i < _cardScaleLabels.length; i++)
                          Expanded(
                            child: Text(
                              _cardScaleLabels[i],
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontWeight: draftLevel == i
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: ShqSpace.sm),
                    // 小样卡：即使底部面板遮住书架的卡片，也能立刻看到比例变化。
                    Center(
                      child: AnimatedContainer(
                        duration: ShqMotion.fast,
                        curve: Curves.easeOutCubic,
                        width: 80 + draftLevel * 26,
                        height: 106 + draftLevel * 34,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(ShqRadius.md),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _cardScaleLabels[draftLevel],
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _content(List<Workbook> visible) {
    final Widget body = _grid ? _gridView(visible) : _list(visible);
    // 双指捏合改卡片大小（2026-10-24 用户第 5 条）。
    //
    // 用自定义的 `_TwoFingerScaleRecognizer`：**只有落到第二根手指时才 accept**，
    // 单指照常交给 GridView/ListView 滚动、交给卡片的点击与长按——
    // 直接用 `GestureDetector(onScaleUpdate:)` 会在单指时把滚动抢掉。
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures:
          <
            Type,
            GestureRecognizerFactoryWithHandlers<_TwoFingerScaleRecognizer>
          >{
            _TwoFingerScaleRecognizer:
                GestureRecognizerFactoryWithHandlers<_TwoFingerScaleRecognizer>(
                  _TwoFingerScaleRecognizer.new,
                  (_TwoFingerScaleRecognizer instance) {
                    instance
                      ..onStart = (ScaleStartDetails details) {
                        if (details.pointerCount >= 2) {
                          _pinchBase = _cardScale;
                        }
                      }
                      ..onUpdate = (ScaleUpdateDetails details) {
                        if (details.pointerCount < 2) {
                          return;
                        }
                        final double next = (_pinchBase * details.scale).clamp(
                          0.75,
                          1.55,
                        );
                        if ((next - _cardScale).abs() < 0.004) {
                          return;
                        }
                        setState(() => _cardScale = next);
                      }
                      ..onEnd = (ScaleEndDetails details) {
                        unawaited(_saveScale());
                      };
                  },
                ),
          },
      child: body,
    );
  }

  Widget _gridView(List<Workbook> items) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.md,
            ShqSpace.md,
            ShqSpace.md,
            96,
          ),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            // 下限 150 而不是 135：`MaxCrossAxisExtent` 会按列数**向下取整**实际
            // 宽度（848dp 屏上 135 会变成 7 列 × 116dp），最小时卡片会窄到
            // 元信息行/文件夹 chip 溢出。150 保证最窄一档仍有 ~136dp。
            maxCrossAxisExtent: (180 * _cardScale).clamp(150, 280),
            mainAxisSpacing: ShqSpace.sm,
            crossAxisSpacing: ShqSpace.sm,
            childAspectRatio: 0.62,
          ),
          itemCount: items.length,
          itemBuilder: (BuildContext context, int index) {
            final Workbook wb = items[index];
            return _WorkbookGridTile(
              workbook: wb,
              selecting: _selectionMode,
              selected: _selected.contains(wb.id),
              folderLabel: _folderLabelOf(wb),
              folderColor: _folderColorOf(wb.folderId),
              tagColorOf: _tagColorOf,
              onTagLongPress: () => unawaited(_editTags(wb)),
              onTap: () => _selectionMode ? _toggleSelected(wb.id) : _open(wb),
              onLongPress: () =>
                  _selectionMode ? _toggleSelected(wb.id) : _openMenu(wb),
            );
          },
        ),
      ),
    );
  }

  Widget _list(List<Workbook> items) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ShqLayout.maxReadingWidth),
        child: ListView.separated(
          // 始终可滚动：空结果态时 RefreshIndicator 也需要一个能滚动的 child
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.md,
            ShqSpace.md,
            ShqSpace.md,
            96,
          ),
          itemCount: items.length,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(height: ShqSpace.sm),
          itemBuilder: (BuildContext context, int index) {
            final Workbook wb = items[index];
            return _WorkbookTile(
              workbook: wb,
              selecting: _selectionMode,
              selected: _selected.contains(wb.id),
              folderLabel: _folderLabelOf(wb),
              folderColor: _folderColorOf(wb.folderId),
              tagColorOf: _tagColorOf,
              onTagLongPress: () => unawaited(_editTags(wb)),
              onTap: () => _selectionMode ? _toggleSelected(wb.id) : _open(wb),
              onLongPress: () =>
                  _selectionMode ? _toggleSelected(wb.id) : _openMenu(wb),
            );
          },
        ),
      ),
    );
  }

  void _open(Workbook workbook) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.reader,
        arguments: ReaderRouteArgs(workbookId: workbook.id),
      ),
    );
  }
}

class _WorkbookTile extends ConsumerWidget {
  const _WorkbookTile({
    required this.workbook,
    required this.onTap,
    required this.onLongPress,
    required this.folderLabel,
    required this.folderColor,
    required this.tagColorOf,
    this.onTagLongPress,
    this.selecting = false,
    this.selected = false,
  });

  final Workbook workbook;

  /// 文件损坏时置灰 + 改弹提示，由本 widget 自己判断（健康探测见
  /// [workbookHealthProvider]）。
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// 已解析好的文件夹名（'' = 未分类）与它的颜色：卡片不自己去查表。
  final String folderLabel;
  final Color folderColor;

  /// 标签 → 颜色（用户设过优先，否则按名字稳定分配）。
  final Color Function(String tag) tagColorOf;

  /// 长按书签：打开「编辑标签」（配色就在里面）。
  final VoidCallback? onTagLongPress;

  /// 多选态：显示勾选框，点/长按都切换选中。
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    // 缩略图：有就读字节，缺了就懒重建（清缓存/恢复备份后不再整排空白）。
    final AsyncValue<Uint8List?> thumb = ref.watch(
      workbookThumbnailProvider(workbook.id),
    );
    final Uint8List? thumbBytes = thumb.maybeWhen<Uint8List?>(
      data: (Uint8List? value) => value,
      orElse: () => null,
    );

    // 文件损坏态：库里有记录、但 Vault 里的 PDF 没了。书架先置灰告知，
    // 而不是让用户点进去才在阅读器里撞错误。
    final AsyncValue<bool> health = ref.watch(
      workbookHealthProvider(workbook.id),
    );
    final bool broken = health.maybeWhen<bool>(
      data: (bool ok) => !ok,
      orElse: () => false,
    );

    void handleTap() {
      if (selecting) {
        onTap();
        return;
      }
      if (broken) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('这份卷的文件缺失了。长按可以删除它，然后重新导入。'),
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }
      onTap();
    }

    return Opacity(
      opacity: broken ? 0.55 : 1,
      child: Stack(
        // 书签压在卡片顶边上：Stack 默认 hardEdge 会裁掉它，必须显式关掉。
        clipBehavior: Clip.none,
        children: <Widget>[
          Pressable(
            onTap: handleTap,
            onLongPress: onLongPress,
            scale: 0.985,
            child: Card(
              clipBehavior: Clip.antiAlias,
              color: selected
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.28)
                  : null,
              // 列表行同款选中光晕（见大图卡注释）。
              elevation: selected ? 5 : 0,
              shadowColor: selected
                  ? theme.colorScheme.primary.withValues(
                      alpha: ShqGlow.selectedAlpha,
                    )
                  : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.md,
                  ShqSpace.md,
                  ShqSpace.sm,
                  ShqSpace.md,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (selecting)
                      Padding(
                        padding: const EdgeInsets.only(right: ShqSpace.xs),
                        child: Icon(
                          selected
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                        ),
                      ),
                    Stack(
                      children: <Widget>[
                        _Thumb(
                          image: thumbBytes,
                          loading: thumb.isLoading,
                        ),
                        if (broken)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              color: theme.colorScheme.error,
                              padding: const EdgeInsets.symmetric(
                                vertical: ShqSpace.xxs,
                              ),
                              child: Text(
                                '文件缺失',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onError,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: ShqSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              workbook.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: <Widget>[
                              _Meta(
                                icon: Icons.description_outlined,
                                text: '${workbook.pageCount} 页',
                              ),
                              const SizedBox(width: ShqSpace.md),
                              _Meta(
                                icon: Icons.schedule,
                                text: formatRelativeTime(workbook.sortTime),
                              ),
                              const Spacer(),
                              // 菜单按钮从标题行挪到这里（2026-10-24）：
                              // 卡片右上角让给标签书签了，两者不能抢同一块地方。
                              if (!selecting)
                                IconButton(
                                  tooltip: '更多操作',
                                  onPressed: onLongPress,
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                  icon: const Icon(Icons.more_horiz, size: 20),
                                ),
                            ],
                          ),
                          // 文件夹归属：标签已经变成右上角书签，这里只留文件夹。
                          if (folderLabel.isNotEmpty) ...<Widget>[
                            const SizedBox(height: ShqSpace.sm),
                            Wrap(
                              spacing: ShqSpace.xs,
                              runSpacing: ShqSpace.xxs,
                              children: <Widget>[
                                _Chip(
                                  icon: Icons.folder_outlined,
                                  label: folderLabel,
                                  emphasized: true,
                                  color: folderColor,
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 往里挪一档（top xs / right md）而不是贴着角：卡片圆角是
          // ShqRadius.lg(20)，书签的直角尖曾戳出圆弧之外。列表卡文字仍横向。
          if (!selecting && workbook.tags.isNotEmpty)
            Positioned(
              top: ShqSpace.xs,
              right: ShqSpace.md,
              child: TagBookmarks(
                tags: workbook.tags,
                colorOf: tagColorOf,
                // 长按任何一枚书签都打开同一个「编辑标签」（配色在里面），
                // 所以不需要知道具体是哪一枚。
                onLongPress: onTagLongPress == null
                    ? null
                    : (String _) => onTagLongPress!(),
              ),
            ),
        ],
      ),
    );
  }
}

/// 大图卡片（书架"大图"模式）。
///
/// 列表卡强调"一行能扫多少卷"，大图卡强调"封面/卷面一眼认出来"。
/// 两者共用同一套数据与选中态；卡片宽度由 `cardScale` 控制。
class _WorkbookGridTile extends ConsumerWidget {
  const _WorkbookGridTile({
    required this.workbook,
    required this.onTap,
    required this.onLongPress,
    required this.folderLabel,
    required this.folderColor,
    required this.tagColorOf,
    this.onTagLongPress,
    this.selecting = false,
    this.selected = false,
  });

  final Workbook workbook;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  final String folderLabel;
  final Color folderColor;
  final Color Function(String tag) tagColorOf;
  final VoidCallback? onTagLongPress;

  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AsyncValue<Uint8List?> thumb = ref.watch(
      workbookThumbnailProvider(workbook.id),
    );
    final Uint8List? thumbBytes = thumb.maybeWhen<Uint8List?>(
      data: (Uint8List? value) => value,
      orElse: () => null,
    );
    final AsyncValue<bool> health = ref.watch(
      workbookHealthProvider(workbook.id),
    );
    final bool broken = health.maybeWhen<bool>(
      data: (bool ok) => !ok,
      orElse: () => false,
    );

    void handleTap() {
      if (selecting) {
        onTap();
        return;
      }
      if (broken) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('这份卷的文件缺失了。长按可以删除它，然后重新导入。'),
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }
      onTap();
    }

    return Opacity(
      opacity: broken ? 0.55 : 1,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Pressable(
            onTap: handleTap,
            onLongPress: onLongPress,
            scale: 0.985,
            child: Card(
              clipBehavior: Clip.antiAlias,
              color: selected
                  ? scheme.primaryContainer.withValues(alpha: 0.28)
                  : null,
              // 选中光晕（2026-10-26）：多选时卡片带一圈同色光。
              // 走 Card 自己的 elevation + shadowColor，而不是外面再包一层：
              // 少一层 widget、不用重排缩进，阴影形状天生跟圆角一致。
              elevation: selected ? 6 : 0,
              shadowColor: selected
                  ? scheme.primary.withValues(alpha: ShqGlow.selectedAlpha)
                  : null,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  // 最窄一档（~130dp）才换紧凑排法；「较小 / 标准」仍有完整两行元信息。
                  final bool narrow = constraints.maxWidth < 150;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            _Thumb(
                              image: thumbBytes,
                              loading: thumb.isLoading,
                              width: double.infinity,
                              height: double.infinity,
                            ),
                            if (broken)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  color: scheme.error,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: ShqSpace.xxs,
                                  ),
                                  child: Text(
                                    '文件缺失',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: scheme.onError,
                                    ),
                                  ),
                                ),
                              ),
                            if (selecting)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: scheme.surface.withValues(
                                      alpha: 0.92,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    selected
                                        ? Icons.check_circle
                                        : Icons.radio_button_unchecked,
                                    color: selected
                                        ? scheme.primary
                                        : scheme.outline,
                                    size: 24,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          ShqSpace.md,
                          ShqSpace.sm,
                          ShqSpace.md,
                          ShqSpace.md,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              workbook.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: narrow
                                  ? theme.textTheme.titleSmall?.copyWith(
                                      fontSize: 13,
                                      height: 1.3,
                                    )
                                  : theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 2),
                            // 页数 · 时间 · 文件夹 **同一行**（2026-10-24）：
                            // 文件夹单独占一行时，有/没有文件夹的卡片高度差一截，
                            // 网格里看上去就是"卡片没对齐"。
                            Row(
                              children: <Widget>[
                                // 「页数 · 时间」合成一段文本：两个图标在窄卡上
                                // 要吃掉 ~40dp，元信息自己就没地方了。
                                Flexible(
                                  flex: 3,
                                  child: Text(
                                    '${workbook.pageCount} 页 · '
                                    '${formatRelativeTime(workbook.sortTime)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 10.5,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                                if (folderLabel.isNotEmpty) ...<Widget>[
                                  const SizedBox(width: ShqSpace.xs),
                                  // 文件夹跟上面那段**平级**：各占一份宽度，
                                  // 不够就一起用省略号，而不是把谁挤没。
                                  Flexible(
                                    flex: 2,
                                    child: _Chip(
                                      icon: Icons.folder_outlined,
                                      label: folderLabel,
                                      emphasized: true,
                                      color: folderColor,
                                      maxWidth:
                                          (constraints.maxWidth -
                                              ShqSpace.md * 2) *
                                          0.45,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          // 多选时右上角是勾选圈，书签让位（同一块地方不能有两样东西）。
          // 大图卡：文字竖排 + 书签收窄，既避开 20dp 圆角，也不压缩略图。
          if (!selecting && workbook.tags.isNotEmpty)
            Positioned(
              top: ShqSpace.xs,
              right: ShqSpace.md,
              child: TagBookmarks(
                tags: workbook.tags,
                colorOf: tagColorOf,
                max: 2,
                vertical: true,
                onLongPress: onTagLongPress == null
                    ? null
                    : (String _) => onTagLongPress!(),
              ),
            ),
        ],
      ),
    );
  }
}

/// 卡片元信息（图标 + 一行小字）。
class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// 书架卡片上的小 chip（文件夹 / 标签）。
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    this.icon,
    this.emphasized = false,
    this.maxWidth,
    this.color,
  });

  final String label;
  final IconData? icon;
  final bool emphasized;

  /// 所在卡片给的可用宽度。null = 列表卡，用默认上限。
  final double? maxWidth;

  /// 自定义色（文件夹的颜色）；null = 用主题色。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color tint = color ?? (emphasized ? scheme.primary : scheme.outlineVariant);
    final Color fg = color ?? (emphasized ? scheme.primary : scheme.onSurfaceVariant);
    // 文字上限要减掉容器内边距（12）与图标位（15），再留 1.5 的取整余量，
    // 否则 chip 本身会以亚像素差超出卡片（真机上表现为右边一条黑黄条）。
    final double labelMax =
        (maxWidth == null ? 140.0 : maxWidth! - (icon == null ? 12 : 27) - 1.5)
            .clamp(20.0, 140.0)
            .toDouble();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ShqRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 3),
          ],
          // 文字要能**继续收缩**：卡片最窄一档时 chip 外层的可用宽度可能比
          // labelMax 还小（Flexible 给的是上界），只包 ConstrainedBox 会硬顶出去
          // 6–7px（真机表现为右边缘黑黄条，2026-10-25 修）。
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: labelMax),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: fg),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 文件夹页顶部的一行"当前文件夹 + 选择文件"。
///
/// 只在这一页出现：用户点进一个文件夹，最想做的事通常不是再导入一份新 PDF，
/// 而是把书架里已有的卷（尤其未分类）收进来。入口放在看得见的地方，
/// 而不是藏进多选菜单或长按里。
class _FolderTargetBar extends StatelessWidget {
  const _FolderTargetBar({
    required this.folder,
    required this.count,
    required this.onSelectFiles,
  });

  final String folder;
  final int count;
  final VoidCallback onSelectFiles;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(ShqSpace.lg, 2, ShqSpace.md, 6),
        child: Row(
          children: <Widget>[
            Icon(Icons.folder_open, size: 17, color: scheme.primary),
            const SizedBox(width: ShqSpace.sm),
            Expanded(
              child: Text(
                '「$folder」 · $count 卷',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: onSelectFiles,
              icon: const Icon(Icons.playlist_add, size: 18),
              label: const Text('选择文件'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: ShqSpace.md),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「选择文件」浮层：从已导入的卷里多选，加入当前文件夹。
///
/// 刻意做成 **可搜索 + 全选 + 明确计数**：几十卷时逐条点很累；而"到底会加几卷"
/// 必须在按钮上写清楚，不能点完再猜。
class _AddToFolderSheet extends StatefulWidget {
  const _AddToFolderSheet({
    required this.folder,
    required this.candidates,
    required this.onImport,
  });

  final String folder;

  /// 已经在目标文件夹里的卷不出现（没有"加入"的意义）。
  final List<Workbook> candidates;

  /// 候选为空时的下一步：去导入新 PDF。
  final VoidCallback onImport;

  @override
  State<_AddToFolderSheet> createState() => _AddToFolderSheetState();
}

class _AddToFolderSheetState extends State<_AddToFolderSheet> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _picked = <String>{};
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Workbook> get _visible => filterByQuery(widget.candidates, _query);

  void _toggle(String id) {
    setState(() {
      if (!_picked.add(id)) {
        _picked.remove(id);
      }
    });
  }

  void _toggleAllVisible() {
    final List<String> ids = _visible.map((Workbook w) => w.id).toList();
    final bool all = ids.every(_picked.contains);
    setState(() {
      if (all) {
        _picked.removeAll(ids);
      } else {
        _picked.addAll(ids);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<Workbook> visible = _visible;
    final bool hasCandidates = widget.candidates.isNotEmpty;
    // 键盘弹起时可用高度变少：上限按"屏高 - 键盘"算，再把键盘作为底部留白，
    // 否则搜索框会被顶出屏幕。
    final double keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final double maxSheetHeight =
        (MediaQuery.sizeOf(context).height - keyboard) * 0.82;
    // 按候选数量给高度：3 份卷时不要把浮层拉满全屏、底部留一大片空白。
    final double wantedHeight = widget.candidates.isEmpty
        ? 420.0
        : 280.0 + widget.candidates.length * 76.0;
    final double sheetHeight = wantedHeight < maxSheetHeight
        ? wantedHeight
        : maxSheetHeight;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: sheetHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.lg,
                  0,
                  ShqSpace.lg,
                  ShqSpace.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('选择文件', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      hasCandidates
                          ? '从已导入的卷里挑，加入「${widget.folder}」；未分类的排在前面。'
                          : '书架上的卷都已经在「${widget.folder}」里了。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasCandidates) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: ShqSpace.lg),
                  child: TextField(
                    controller: _search,
                    onChanged: (String value) => setState(() => _query = value),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: '搜索标题 / 标签 / 文件夹',
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: ShqSpace.sm),
                // Flexible + shrinkWrap：3 份卷时列表只占内容高度，把底栏
                // 紧贴在列表下面；候选很多时才吃满剩余高度并滚动。
                Flexible(
                  child: visible.isEmpty
                      ? Center(
                          child: Text(
                            '没有匹配「$_query」的卷子',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: ShqSpace.sm,
                          ),
                          itemCount: visible.length,
                          separatorBuilder: (BuildContext context, int index) =>
                              Divider(
                                height: 1,
                                indent: ShqSpace.lg,
                                endIndent: ShqSpace.lg,
                                color: scheme.outlineVariant.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                          itemBuilder: (BuildContext context, int index) {
                            final Workbook wb = visible[index];
                            final bool checked = _picked.contains(wb.id);
                            return InkWell(
                              onTap: () => _toggle(wb.id),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: ShqSpace.sm,
                                  vertical: ShqSpace.xs,
                                ),
                                child: Row(
                                  children: <Widget>[
                                    Checkbox(
                                      value: checked,
                                      onChanged: (bool? _) => _toggle(wb.id),
                                      visualDensity: VisualDensity.compact,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    const SizedBox(width: ShqSpace.xs),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          Text(
                                            wb.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                          const SizedBox(height: 1),
                                          Text(
                                            '${wb.pageCount} 页 · '
                                            '${wb.isUnfiled ? '未分类' : '在「${wb.folder}」'}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                  fontSize: 11,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    ShqSpace.md,
                    ShqSpace.xs,
                    ShqSpace.lg,
                    ShqSpace.sm,
                  ),
                  child: Row(
                    children: <Widget>[
                      TextButton(
                        onPressed: _toggleAllVisible,
                        child: Text(
                          visible.every((Workbook w) => _picked.contains(w.id))
                              ? '取消全选'
                              : '全选',
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '已选 ${_picked.length} / ${widget.candidates.length}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: ShqSpace.md),
                      FilledButton.icon(
                        onPressed: _picked.isEmpty
                            ? null
                            : () =>
                                  Navigator.of(context)
                                      .pop(_picked.toList(growable: false)),
                        icon: const Icon(
                          Icons.drive_file_move_outline,
                          size: 18,
                        ),
                        label: Text(
                          _picked.isEmpty ? '加入' : '加入 ${_picked.length} 卷',
                        ),
                      ),
                    ],
                  ),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    ShqSpace.lg,
                    ShqSpace.md,
                    ShqSpace.lg,
                    ShqSpace.xl,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.inbox_outlined,
                        size: 30,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: ShqSpace.sm),
                      Text('没有可加入的卷子', style: theme.textTheme.titleSmall),
                      const SizedBox(height: ShqSpace.xxs),
                      Text(
                        '先导入一份 PDF，或在「全部」里把其他文件夹的卷移出来。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: ShqSpace.md),
                      FilledButton.icon(
                        onPressed: widget.onImport,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('导入 PDF'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 书签组件在 ui/bookshelf/tag_bookmark.dart（卡片与「编辑标签」弹窗共用）──

/// 文件夹筛选条：一条可横向滚动的小 chip 行。
///
/// 设计取舍：不做"左侧文件夹树"——书架是平铺列表，几十卷的场景下
/// 一条横条比一棵树更省地方，也不会把有限的横向空间吃掉一半。
/// 文件夹筛选条（v4：支持嵌套）。
///
/// 一行横向滚动，内容按"在最里面的位置"排：
/// `‹ 上一层`（有路径时）→ `全部` → `未分类` → **当前层的子文件夹** → `新建`。
///
/// 为什么不画成一棵竖树：书架已经在做 Obsidian 式树视图（[ShelfTree]），
/// 这条栏的职责是"横向切换层级"，两者互补——树负责看全貌，这条负责快速跳。
class _FolderBar extends StatelessWidget {
  const _FolderBar({
    required this.folders,
    required this.foldersWithChildren,
    required this.path,
    required this.selectedId,
    required this.onSelected,
    required this.onManageFolder,
    required this.onCreateFolder,
    required this.unfiledCount,
    required this.total,
  });

  /// 当前层的子文件夹。
  final List<ShelfFolder> folders;

  /// 哪些文件夹里面还有子文件夹（决定 chip 末尾那个 ›）。
  ///
  /// 只传 id 集合而不是整棵树：chip 行不需要知道子级是谁，只要知道"还能往下走"。
  final Set<String> foldersWithChildren;

  /// 从根到当前的路径（空 = 在顶层）。
  final List<ShelfFolder> path;

  /// null = 全部；'' = 未分类；其它 = 文件夹 id。
  final String? selectedId;
  final ValueChanged<String?> onSelected;

  /// 长按文件夹 chip：重命名 / 颜色 / 删除。
  final ValueChanged<ShelfFolder> onManageFolder;

  final VoidCallback onCreateFolder;
  final int unfiledCount;
  final int total;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: ShqSpace.md),
        children: <Widget>[
          // 在子文件夹里：给一个明确的"回上一层"。
          if (path.isNotEmpty)
            _FolderChip(
              label: path.length > 1 ? path[path.length - 2].name : '全部',
              icon: Icons.arrow_back,
              selected: false,
              onTap: () =>
                  onSelected(path.length > 1 ? path[path.length - 2].id : null),
            ),
          _FolderChip(
            label: '全部',
            icon: Icons.apps,
            selected: selectedId == null,
            onTap: () => onSelected(null),
          ),
          if (unfiledCount > 0)
            _FolderChip(
              label: '未分类',
              icon: Icons.inbox_outlined,
              selected: selectedId == '',
              onTap: () => onSelected(''),
            ),
          for (final ShelfFolder folder in folders)
            _FolderChip(
              label: folder.name,
              icon: Icons.folder_outlined,
              color: folder.color.isEmpty ? null : shqHexColor(folder.color),
              hasChildren: foldersWithChildren.contains(folder.id),
              selected: selectedId == folder.id,
              onTap: () => onSelected(folder.id),
              onLongPress: () => onManageFolder(folder),
            ),
          _FolderChip(
            label: '新建',
            icon: Icons.create_new_folder_outlined,
            selected: false,
            onTap: onCreateFolder,
          ),
          if (path.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: ShqSpace.sm),
              child: Center(
                child: Text(
                  path.map((ShelfFolder f) => f.name).join(' / '),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                    fontSize: ShqType.caption,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FolderChip extends StatelessWidget {
  const _FolderChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.color,
    this.hasChildren = false,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 文件夹自带的颜色（用户设的）；null = 用主题色。
  final Color? color;

  /// 里面还有子文件夹：末尾加一个 ›，一眼看出"还能往里走"（需求 8 嵌套）。
  final bool hasChildren;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: ShqSpace.sm),
      child: Center(
        child: Pressable(
          onTap: onTap,
          onLongPress: onLongPress,
          scale: 0.94,
          haptic: true,
          child: AnimatedContainer(
            duration: ShqMotion.base,
            curve: ShqMotion.curveEmphasized,
            padding: const EdgeInsets.symmetric(
              horizontal: ShqSpace.md,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              // 选中：有自定义色就用它（浅底），否则主题的 secondaryContainer。
              color: selected
                  ? (color?.withValues(alpha: 0.16) ??
                        scheme.secondaryContainer)
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShqRadius.pill),
              border: Border.all(
                color: selected
                    ? (color ?? scheme.secondaryContainer)
                    : scheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  icon,
                  size: 15,
                  color: selected
                      ? (color ?? scheme.onSecondaryContainer)
                      : (color ?? scheme.onSurfaceVariant),
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected
                        ? (color ?? scheme.onSecondaryContainer)
                        : scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (hasChildren) ...<Widget>[
                  const SizedBox(width: 2),
                  Icon(
                    Icons.chevron_right,
                    size: 13,
                    color: selected
                        ? (color ?? scheme.onSecondaryContainer)
                        : scheme.outline,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.image,
    this.loading = false,
    this.width = 64,
    this.height = 88,
  });

  final Uint8List? image;
  final bool loading;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ShqRadius.sm),
        border: Border.all(color: scheme.outlineVariant),
        // 极浅的投影：只让缩略图从卡片上"浮"起一点点，不抢标题。
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(
              alpha: scheme.brightness == Brightness.dark ? 0.35 : 0.06,
            ),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ShqRadius.sm - 1),
        child: image != null
            ? Image.memory(
                image!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder:
                    (BuildContext context, Object error, StackTrace? stackTrace) {
                      return _placeholder(scheme);
                    },
              )
            : loading
            ? ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: scheme.outline,
                    ),
                  ),
                ),
              )
            : _placeholder(scheme),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) {
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(
        Icons.description_outlined,
        size: 24,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onImport});

  final Future<void> Function() onImport;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.library_books_outlined,
      title: '还没有导入任何卷子',
      message: '把第一份真题 PDF 导进来，就能开始刷了',
      actionLabel: '导入 PDF',
      onAction: () => unawaited(onImport()),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: ShqLayout.maxNarrativeWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.all(ShqSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SoftIcon(
                icon: Icons.cloud_off_outlined,
                size: 88,
                iconSize: 36,
                circle: true,
                background: scheme.errorContainer.withValues(alpha: 0.45),
                color: scheme.onErrorContainer,
              ),
              const SizedBox(height: ShqSpace.lg),
              Text('书架读取失败', style: theme.textTheme.titleLarge),
              const SizedBox(height: ShqSpace.xs),
              Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: ShqSpace.lg),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 相对时间。`utcMillis` 是库里存的 UTC 毫秒，显示时转本地。
String formatRelativeTime(int utcMillis, {DateTime? now}) {
  final DateTime at = DateTime.fromMillisecondsSinceEpoch(utcMillis);
  final DateTime current = now ?? DateTime.now();
  final Duration diff = current.difference(at);
  if (diff.inMinutes < 1) {
    return '刚刚';
  }
  if (diff.inHours < 1) {
    return '${diff.inMinutes} 分钟前';
  }
  if (diff.inDays < 1) {
    return '${diff.inHours} 小时前';
  }
  if (diff.inDays < 30) {
    return '${diff.inDays} 天前';
  }
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)}';
}

/// 只在**第二根手指落下之后**才接受比赛的缩放手势。
///
/// 为什么不用 `GestureDetector(onScaleUpdate:)`：它的 `ScaleGestureRecognizer`
/// 单指也会 accept，会把 GridView / ListView 的滚动抢走（书架直接滑不动）。
/// 这里单指时干脆不接受、让滚动与卡片的点击长按赢；第二指落下立刻 accept，
/// 之后 onUpdate 里的 `details.scale` 就是连续倍率。
class _TwoFingerScaleRecognizer extends ScaleGestureRecognizer {
  bool _accepted = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _accepted = false;
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    if (!_accepted && pointerCount >= 2) {
      _accepted = true;
      resolve(GestureDisposition.accepted);
    }
  }
}
