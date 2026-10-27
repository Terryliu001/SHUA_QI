import 'dart:io';

import 'package:flutter/services.dart';

/// 设备信息（反馈里带一段"什么设备、什么系统"，方便定位）。
///
/// 为什么不引 `device_info_plus`：白名单里虽然允许，但为了一个型号字符串
/// 加一个插件不划算。主 Activity 已经有 MethodChannel，加一个 `deviceInfo`
/// 分支就是几行 Kotlin，还不影响包体。
///
/// 只取**非个人**信息：厂商 + 型号 + Android 版本 + API 级别。
/// 不取 IMEI / 序列号 / 广告 id / 账号 —— 反馈不需要，也不该收。
abstract final class DeviceInfo {
  static const MethodChannel _channel = MethodChannel('com.shuaqi.shuaqi/media');

  static String? _cached;

  /// 形如 `OPPO OPD2601 / Android 16 / API 36`；取不到时退回系统名。
  static Future<String> describe() async {
    final String? cached = _cached;
    if (cached != null) {
      return cached;
    }
    try {
      final Map<String, Object?>? info = await _channel
          .invokeMapMethod<String, Object?>('deviceInfo')
          .timeout(const Duration(seconds: 2));
      final String model = (info?['model'] as String?)?.trim() ?? '';
      final String android = (info?['android'] as String?)?.trim() ?? '';
      final Object? sdk = info?['sdk'];
      final List<String> parts = <String>[
        if (model.isNotEmpty) model,
        if (android.isNotEmpty) 'Android $android',
        if (sdk != null) 'API $sdk',
      ];
      if (parts.isNotEmpty) {
        _cached = parts.join(' / ');
        return _cached!;
      }
    } on Object {
      // 通道不可用（例如测试环境）：退回平台名，不抛。
    }
    _cached = Platform.operatingSystem;
    return _cached!;
  }
}
