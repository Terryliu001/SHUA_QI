import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/ui/region/region_action.dart';

/// 锁定语义（2026-10-26 用户第 18 条）。
///
/// 用户原话："点击『锁定』不能实现更改功能被锁，还是可以拖框或者做切开并入等操作，
/// 这里修复一下，锁定后，仅保留改题号功能开放，解除锁定才能做别的"。
///
/// 所以规则只有一条：**锁定 → 只剩「解锁」与「改题号」**。
/// 拖框 / 切开 / 并入 / 跨页 / 加题 / 删除全部禁用。
void main() {
  test('锁定后只保留解锁与改题号', () {
    final Set<RegionAction> allowed = allowedActionsWhenLocked();
    expect(allowed.length, 2);
    expect(allowed.contains(RegionAction.lock), isTrue);
    expect(allowed.contains(RegionAction.rename), isTrue);
  });

  test('锁定后拖框类动作全部禁用', () {
    final Set<RegionAction> allowed = allowedActionsWhenLocked();
    for (final RegionAction action in <RegionAction>[
      RegionAction.split,
      RegionAction.merge,
      RegionAction.extend,
      RegionAction.delete,
      RegionAction.addQuestion,
    ]) {
      expect(
        allowed.contains(action),
        isFalse,
        reason: '${action.name} 在锁定时必须禁用',
      );
    }
  });

  test('改题号的文案与图标照旧（锁定不影响它）', () {
    expect(regionActionLabel(RegionAction.rename, locked: true), '改题号');
    expect(regionActionLabel(RegionAction.lock, locked: true), '解锁');
    expect(regionActionLabel(RegionAction.lock, locked: false), '锁定');
  });
}
