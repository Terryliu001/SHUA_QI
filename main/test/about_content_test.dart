import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/app/about_content.dart';

/// 「关于」里的版本说明与用户须知（2026-10-26 用户第 2 条）。
///
/// ## 为什么这些文案要测
/// 它们是**产品承诺**：用户按「用户须知」判断要不要给这个应用权限、
/// 要不要把 Key 填进去。写错了不是文案问题，是产品失信。
///
/// 所以这里钉住三件事：
/// 1. 结构完整（每条都有标题/摘要，不留空段）；
/// 2. 关键口径**在**（权限、API 调度、数据位置、隐私、限制）；
/// 3. 不承诺没做的能力（"已知限制"必须存在）。
void main() {
  test('版本说明非空，且第一条带日期与限制', () {
    expect(kReleaseNotes, isNotEmpty);
    final ReleaseNote first = kReleaseNotes.first;
    expect(first.version, isNotEmpty);
    expect(first.date, isNotEmpty);
    // 0.1.2 是纯修复版本（没有新功能），所以"第一条有内容"允许落在 fixed 上；
    // 早期版本都带 added。这条断言的本意是"别发布一条空版本说明"。
    expect(
      first.added.isNotEmpty ||
          first.changed.isNotEmpty ||
          first.fixed.isNotEmpty,
      isTrue,
      reason: '第一版总得写点"新增/变更/修复"',
    );
    expect(
      first.limits,
      isNotEmpty,
      reason: '已知限制必须写出来，不能藏着',
    );
  });

  test('版本说明里没有空句子', () {
    for (final ReleaseNote note in kReleaseNotes) {
      for (final List<String> group in <List<String>>[
        note.added,
        note.changed,
        note.fixed,
        note.limits,
      ]) {
        for (final String item in group) {
          expect(item.trim(), isNotEmpty);
        }
      }
    }
  });

  test('用户须知覆盖五个必答板块', () {
    final String blob = kUserNotice
        .map((NoticeSection s) => '${s.title}\n${s.summary}\n${s.bullets.join('\n')}')
        .join('\n');
    for (final String keyword in <String>[
      '数据',
      '权限',
      'AI',
      '隐私',
      '限制',
    ]) {
      expect(blob, contains(keyword), reason: '须知里必须有「$keyword」');
    }
  });

  test('用户须知写清了"只申请网络权限"与"没有云同步"', () {
    final String blob = kUserNotice
        .map((NoticeSection s) => '${s.title}\n${s.summary}\n${s.bullets.join('\n')}')
        .join('\n');
    expect(blob, contains('INTERNET'));
    expect(blob, contains('没有云同步'));
  });

  test('用户须知每一节都有标题与一句结论', () {
    for (final NoticeSection section in kUserNotice) {
      expect(section.title.trim(), isNotEmpty);
      expect(section.summary.trim(), isNotEmpty);
      expect(section.bullets, isNotEmpty, reason: '${section.title} 要有正文');
      for (final String bullet in section.bullets) {
        expect(bullet.trim(), isNotEmpty);
      }
    }
  });
}
