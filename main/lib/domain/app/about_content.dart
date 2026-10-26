/// 「关于」里三段只读内容的**唯一数据源**（纯 Dart，可单测）。
///
/// 为什么放在 domain 而不是写在 widget 里：
/// 1. 这些文案是**产品承诺**（权限、数据在哪、AI 怎么调用），必须能被搜索、
///    被测试钉住"没有承诺不存在的能力"；
/// 2. 版本说明是"随版本增长"的列表，写成数据后，加版本只需加一条；
/// 3. domain 不许 import Flutter，所以这里只有字符串与值对象。
///
/// 纪律：**只写真实存在的能力**。没做的功能不写进"新增"，只写进"已知限制"。
library;

/// 版本说明的一条。
class ReleaseNote {
  const ReleaseNote({
    required this.version,
    required this.date,
    this.added = const <String>[],
    this.changed = const <String>[],
    this.fixed = const <String>[],
    this.limits = const <String>[],
  });

  final String version;

  /// `2026-10-26`
  final String date;

  final List<String> added;
  final List<String> changed;
  final List<String> fixed;

  /// 这一版**明确做不到**的事。写出来比藏着更可信。
  final List<String> limits;

  bool get isEmpty =>
      added.isEmpty && changed.isEmpty && fixed.isEmpty && limits.isEmpty;
}

/// 版本说明（新版本加在**最前面**）。
const List<ReleaseNote> kReleaseNotes = <ReleaseNote>[
  ReleaseNote(
    version: '0.1.0',
    date: '2026-10-26',
    added: <String>[
      '导入 PDF 试卷：可一次多选、串行导入，重复文件会被拦住',
      '阅读：分页 / 连续滚动两种形态，45%–400% 缩放，六种纸感与夜读',
      '手写：钢笔 / 圆珠笔 / 荧光笔，局部擦除，撤销重做 50 步',
      '自动切题：按栏、按行、按题号切出题目框，题目区域里可拖框、切开、并入、锁定、改题号',
      '答题卡：逐题作答纸（尺寸 / 方向 / 张数可调），笔迹每题独立保存',
      '判题：本地规则 + 三色手改，自动结论不覆盖手改',
      'AI（自带 Key）：对题对话、先做一遍、判我的作答、深度思考、公式与代码块排版',
      '收藏夹：跨卷快照、按卷 / 按知识点 / 组卷四视图，单题重刷与组卷连刷',
      '记录：个人空间、26 周热力图、科目与题型词云、7/30 天看板、作答时间线',
      '导出 PDF：原题 / 笔迹 / 答题卡任意组合，落到「下载/SHUAQI」',
    ],
    changed: <String>[
      '「AI 判」改成两个动作：工具行的「AI 补答案」与多选里的「AI 判」',
      '设置「关于」新增版本说明、用户须知、用户反馈三个入口',
      '设置「存储与备份」换成「缓存统计与清除」，并提供整机备份导出 / 恢复',
      '设置可打开「文字模式」：顶栏图标旁带上功能文字',
    ],
    fixed: <String>[
      'AI 判题结果偶尔被判成「格式异常」——解析改成配对扫描，纯文字结论也能接住',
      '锁定题目框后仍能被拖动 / 切开 / 并入——现在只保留「改题号」，解锁才能改框',
      '从答题卡点「重框」再拖框，改的是作答框而不是切题框',
    ],
    limits: <String>[
      '公式只显示原图，不转成可编辑的 LaTeX',
      '手写识别只在「答题情况」里做，答题卡不再单独识别',
      '没有云同步；卸载应用会删除本机全部数据，重要资料请用「导出备份」或「导出 PDF」',
      '组卷与重刷记录统计的是"做过几次"，同一道题当天重刷会多算一次',
    ],
  ),
];

/// 用户须知的一个板块。
class NoticeSection {
  const NoticeSection({
    required this.title,
    required this.summary,
    this.bullets = const <String>[],
  });

  final String title;

  /// 一句话结论（用户只读这一句也不会误解）。
  final String summary;

  final List<String> bullets;
}

/// 用户须知（权限 / API 调度 / 数据位置 / 隐私 / 限制）。
///
/// 顺序是"用户最担心的先答"：数据在哪 → 拿了什么权限 → AI 怎么被调用 →
/// 识别与公式 → 隐私 → 版权 → 已知限制。
const List<NoticeSection> kUserNotice = <NoticeSection>[
  NoticeSection(
    title: '你的数据在哪里',
    summary: '全部在你这一台设备上，应用私有目录里；我们不经过任何服务器。',
    bullets: <String>[
      '试卷原文件、手写笔迹、切题结果、判题、收藏、作答记录都在 App 私有目录（随应用卸载一起删除）。',
      '导出的 PDF 落到系统「下载/SHUAQI」；保存的题目图片落到相册的「Pictures/SHUAQI」。',
      '本版本没有云同步，也不会上传任何内容。卸载前请先用「设置 → 数据 → 导出备份」留一份。',
    ],
  ),
  NoticeSection(
    title: '应用需要哪些权限',
    summary: '只申请了「网络访问」一项，用来调用你自己配置的 AI 接口。',
    bullets: <String>[
      '网络访问（INTERNET）：唯一用途是向你填写的 AI 端点发请求；不联网时刷题、手写、判题、导出全部可用。',
      '选 PDF、选图片走系统文件选择器，应用拿不到相册/文件的全部权限，只得到你亲手挑中的那一个文件。',
      '没有申请存储、相机、麦克风、位置、通讯录、短信等权限。',
      '保存图片到相册、导出到下载目录走系统媒体库接口，不需要额外授权。',
    ],
  ),
  NoticeSection(
    title: 'AI 是怎么被调用的（API 调度说明）',
    summary: '自带 Key，请求直接发往你填的地址；我们不做中转，也不代付费用。',
    bullets: <String>[
      '在「设置 → AI 分析 → AI 配置」里填端点、Key、模型；支持任意 OpenAI 兼容接口。',
      'Key 只存本机应用私有目录，不写入日志、不随导出备份以外的方式外传。',
      '每次请求都由你的操作触发：问 AI、先做一遍、判我的作答、AI 补答案、AI 判、知识点归纳。',
      '批量动作（补答案 / 批量判题 / 归纳）是**逐题串行请求**，按钮上会显示进度；收起面板即可停止后续请求，已完成的会保留。',
      '请求失败、超时或额度不足时，界面会明确报错；不会把半截结果写进判题或答案库。',
      'AI 的结论一律标「AI · 请自检」，与你的手改冲突时，手改永远优先。',
      '费用由你的服务商按调用量计费；本应用只展示 token 用量，不参与结算。',
    ],
  ),
  NoticeSection(
    title: '识别与公式',
    summary: '手写识别只在「答题情况」里自动进行；公式按原图显示。',
    bullets: <String>[
      '答题卡不再单独提供「识别手写」按钮：判题时直接把作答图交给 AI 看。',
      '「题目区域 → 答题情况」仍会在后台把这一题的笔迹识别成文字，用于本地判题与展示。',
      '公式不转 LaTeX，只显示卷面上的原图；AI 回复里的 LaTeX 会正常排版。',
      '扫描件切题可能不准，可在「题目区域」里拖框、切开、并入、锁定，随时可撤销。',
    ],
  ),
  NoticeSection(
    title: '隐私',
    summary: '没有统计、没有广告、没有第三方分析 SDK。',
    bullets: <String>[
      '应用内不含埋点、崩溃上报、广告或社交分享 SDK。',
      '除你主动配置的 AI 请求外，应用不发起任何网络连接。',
      '用户反馈里的手机号只用于修复后回电/短信，且只在你点「提交」后才会上传。',
    ],
  ),
  NoticeSection(
    title: '内容与版权',
    summary: '请只导入你有权使用的试卷，用于个人学习。',
    bullets: <String>[
      '试卷内容的版权归原权利人；本应用只是本地阅读与书写工具。',
      'AI 生成的答案与解析仅供参考，请自行核对。',
    ],
  ),
  NoticeSection(
    title: '已知限制',
    summary: '这些是当前版本明确做不到的，先写在这里，避免误会。',
    bullets: <String>[
      '没有账号、没有云同步、没有自动备份：换设备需要手动导出 / 恢复。',
      '公式不可编辑、不可检索。',
      '热力图与看板按"一题一天"统计；同一道题当天重刷会额外记一次。',
      '回收站没有：删除试卷时，该卷的收藏快照会保留，但卷内笔迹随卷删除。',
    ],
  ),
];
