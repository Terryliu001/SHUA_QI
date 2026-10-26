import 'package:flutter/material.dart';
import 'package:shuaqi/ui/settings/settings_subpage.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 关于 → 使用指南（只读）。
///
/// 写法上刻意**按动作组织**，而不是按代码模块：
/// 用户是来问"这一步怎么做"，不是来读架构说明。
/// 每条都写清入口、结果和不可逆的代价（导出/备份/删除）。
class GuidePage extends StatelessWidget {
  const GuidePage({super.key, required this.onClose});

  final VoidCallback onClose;

  static const List<_GuideSection> _sections = <_GuideSection>[
    _GuideSection(
      icon: Icons.add_circle_outline,
      title: '导入与书架',
      bullets: <String>[
        '书架右下角「导入 PDF」可一次多选；重复文件会被拦住，不会导两份。',
        '长按卷子：重命名 / 移动到文件夹 / 编辑标签 / 删除 / 导出 PDF。',
        '顶部「视图」切换列表 / 大图 / 树视图；双指捏合可改卡片大小。',
        '文件夹可以嵌套；进入外层文件夹后，顶部会出现子文件夹卡，点进去继续看。',
      ],
    ),
    _GuideSection(
      icon: Icons.menu_book_outlined,
      title: '阅读',
      bullets: <String>[
        '顶栏「显示」里切分页 / 连续滚动、纸感、夜读与缩放。',
        '手势模式开：手指只平移缩放、笔书写；关：手指也能写。',
        '顶栏「题目」打开题目区域；「答题卡」进入逐题作答；「缩略」快速翻页。',
        '长按卷面可保存题面图；导出 PDF 始终用原图，不套纸感滤镜。',
      ],
    ),
    _GuideSection(
      icon: Icons.edit_outlined,
      title: '书写与图形',
      bullets: <String>[
        '工具面板里选钢笔 / 圆珠笔 / 荧光笔，颜色与粗细每支笔分别记忆。',
        '橡皮是「划过即擦」的局部擦除；撤销 / 重做在顶栏，最多 50 步。',
        '画完直线、矩形、圆/椭圆、三角形、平行四边形后停笔约半秒，出现预览；抬笔即吸附，继续移动则取消。',
        '粗细调整时，画布上会出现带数值的笔尖提示；滑条右侧也是真实笔触样本。',
      ],
    ),
    _GuideSection(
      icon: Icons.crop_free,
      title: '切题与答题卡',
      bullets: <String>[
        '题目区域里点一条题 → 跳到该页并选中；拖动框、拉四角可改切题范围。',
        '「切开 / 并入上题 / 跨页 / 锁定 / 删除 / 改题号」都可撤销；锁定后只保留改题号。',
        '答题卡「重框」默认调题目框；点返回或停留都会自动保存。',
        '答题卡长按题面可保存题面图；题目面板里可「对答案 / 改卷 / 补答案」。',
      ],
    ),
    _GuideSection(
      icon: Icons.psychology_outlined,
      title: '判题与 AI',
      bullets: <String>[
        '「对答案」只对已有参考答案的题判；本地判不了或不可信时，会问你要不要交给 AI。',
        '工具行「改卷」先跑本地；判不出/不可信的题再询问是否 AI 后台判，手改结论永远优先。',
        '多选「AI 判」：没答案的题先生成答案再判；已有答案直接判；结论写进该题「问 AI」。',
        'AI 配置在「设置 → AI 分析」；点标题旁的 i 看 DeepSeek 配置示例。费用由你的服务商计。',
      ],
    ),
    _GuideSection(
      icon: Icons.bookmark_border,
      title: '收藏与重刷',
      bullets: <String>[
        '收藏是跨卷快照；按全部 / 按试卷 / 按知识点 / 组卷四种视图。',
        '看题页「重刷这道题」打开空白新答题卡；退出时询问是否保存这次重刷记录。',
        '重刷记录以列表呈现在该题下方；点某一次可继续查看/修改，组卷里刷的会标组卷名与时间。',
        '组卷是多道题的命名题集；详情页可改名、加题、移出、长按拖动排序，再「连刷」。',
      ],
    ),
    _GuideSection(
      icon: Icons.insights_outlined,
      title: '记录',
      bullets: <String>[
        '热力图可选近三个月 / 半年 / 一年；今天永远在最后一列。',
        '科目 / 题型词云可以拖动，松手会弹性回到原位。',
        '看板看近 7/30 天的题数、卷数、正确率、判定分布与连续打卡。',
        '作答时间线按试卷或按题目；重刷/组卷记录展开是列表，可打开某一次重刷。',
      ],
    ),
    _GuideSection(
      icon: Icons.ios_share_outlined,
      title: '导出与备份',
      bullets: <String>[
        '书架长按 → 导出 PDF：原题 / 笔迹 / 答题卡任意组合；文件名默认带内容与时间，可手改。',
        '清晰度有标准 / 高清两档；页数多时导出会逐页渲染，请给它一点时间。',
        '设置 → 数据 → 导出备份：zip 含数据库与整个 Vault，落到「下载/SHUAQI」。',
        '从备份恢复会覆盖本机数据；替换前自动留底，恢复后应用会重启。',
      ],
    ),
    _GuideSection(
      icon: Icons.settings_outlined,
      title: '设置与帮助',
      bullets: <String>[
        '外观 → 文字模式：顶栏与工具栏图标旁显示功能文字，窗口窄时自动退回图标。',
        '数据 → 缓存统计与清除：只清缩略图、作答原图裁切、临时文件，不动笔迹与收藏。',
        '关于：使用指南 / 版本说明 / 用户须知 / 用户反馈；版本号连点 8 次打开开发者选项。',
        '反馈里可带最多 3 张截图与手机号；通道未接通时会明确说「只存本机」。',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return SettingsSubPageScaffold(
      page: SettingsSubPage.guide,
      subtitle: '从导入到导出：每一步在哪里、会发生什么',
      onClose: onClose,
      child: SettingsSubPageBody(
        children: <Widget>[
          const _Intro(
            '这是一份按动作写的速查。第一次用建议从「导入与书架」看起；'
            '遇到具体问题，先看对应章节，再通过「用户反馈」告诉我们。',
          ),
          for (final _GuideSection section in _sections)
            _SectionCard(section: section),
          const SizedBox(height: ShqSpace.lg),
        ],
      ),
    );
  }
}

class _GuideSection {
  const _GuideSection({
    required this.icon,
    required this.title,
    required this.bullets,
  });

  final IconData icon;
  final String title;
  final List<String> bullets;
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section});

  final _GuideSection section;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: ShqSpace.md),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            ShqLayout.gutter,
            ShqSpace.md,
            ShqLayout.gutter,
            ShqSpace.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(ShqRadius.sm),
                    ),
                    child: Icon(
                      section.icon,
                      size: 18,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: ShqSpace.sm),
                  Text(
                    section.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: ShqSpace.sm),
              for (final String bullet in section.bullets)
                SubPageBullet(bullet),
            ],
          ),
        ),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
          height: 1.65,
        ),
      ),
    );
  }
}
