import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 可按压容器：**按下时轻微缩小 + 一点透明度**，松开回弹。
///
/// ## 为什么不用水波纹（2026-10-23 设计升级）
/// 这个产品的主输入是笔。水波纹有两件事让笔感变差：
/// 1. 笔尖点一下就在按钮上留一圈光，像"点到水面"，不稳；
/// 2. 波纹扩散会盖住按钮自己的内容（尤其是颜色小圆点）。
///
/// 所以主题里关掉了 splash（`NoSplash.splashFactory`），交互反馈改成
/// "元素自己缩一下"——这是 iOS / ColorOS 现在更常用的语言：
/// 位移幅度小（3%）、时长短（90ms 按下 / 150ms 回弹），手指几乎无感但有回应。
///
/// ## 为什么带轻微的 haptic
/// 平板上的按钮（导入、删除、切工具）都是"有后果"的动作；
/// 一次 `selectionClick` 的轻震能让"我确实点到了"这件事落到手上，
/// 但不会像 `heavyImpact` 那样打断书写。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.97,
    this.haptic = false,
    this.borderRadius,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 按下时的缩放（0.94–0.99 之间比较自然；整块卡片用 0.985）。
  final double scale;

  /// 是否震一下（默认不震；卡片类不加，按钮类加）。
  final bool haptic;

  /// 仅用于把 Material 的 ink 关掉后仍有正确的语义区域（可空）。
  final BorderRadius? borderRadius;

  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _setDown(bool value) {
    if (_down == value) {
      return;
    }
    setState(() => _down = value);
  }

  void _handleTap() {
    if (widget.haptic) {
      unawaitedHaptic();
    }
    widget.onTap?.call();
  }

  void unawaitedHaptic() {
    // 失败（设备不支持）就静默——触觉是锦上添花，不该影响功能。
    HapticFeedback.selectionClick().ignore();
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: enabled ? (_) => _setDown(true) : null,
      onTapUp: enabled ? (_) => _setDown(false) : null,
      onTapCancel: enabled ? () => _setDown(false) : null,
      onTap: widget.onTap == null ? null : _handleTap,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              if (widget.haptic) {
                unawaitedHaptic();
              }
              widget.onLongPress!();
            },
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: _down ? ShqMotion.instant : ShqMotion.fast,
        curve: _down ? ShqMotion.curveStandard : ShqMotion.curveEmphasized,
        child: AnimatedOpacity(
          opacity: _down ? 0.86 : 1,
          duration: _down ? ShqMotion.instant : ShqMotion.fast,
          curve: ShqMotion.curveStandard,
          child: widget.child,
        ),
      ),
    );
  }
}
