import 'dart:math';

/// ULID 生成（规格 §5.3：id 用 ULID，可按时间排序）。
///
/// 不引包：Crockford Base32 编码 128 位（48 位毫秒时间戳 + 80 位随机），26 个字符。
/// 纯 Dart，只依赖 `dart:math`，所以放在 domain 层也不会破坏"domain 不许 import Flutter"的约束。
///
/// 注意：**不保证同一毫秒内单调递增**。排序只在"毫秒级时间不同"时可靠；
/// 同一毫秒内以随机部分比较大小没有意义。真需要严格单调时要加单调计数器，本阶段不需要。
abstract final class Ulid {
  /// Crockford Base32：去掉了 I / L / O / U，避免与 1 / 0 混淆。
  static const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static final Random _random = Random.secure();

  /// 生成一个新 ULID。传 [now] 便于测试；生产代码不要传。
  static String next([DateTime? now]) {
    final int millis = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final List<int> bytes = List<int>.filled(16, 0);

    // 48 位时间戳，大端写进前 6 字节
    for (int i = 0; i < 6; i++) {
      bytes[i] = (millis >> (8 * (5 - i))) & 0xFF;
    }
    // 80 位随机
    for (int i = 6; i < 16; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return _encode(bytes);
  }

  /// 从 ULID 取回生成时间（毫秒时间戳）。解析失败返回 null。
  static int? timestampOf(String ulid) {
    if (ulid.length != 26) {
      return null;
    }
    final List<int>? bytes = _decode(ulid);
    if (bytes == null) {
      return null;
    }
    int millis = 0;
    for (int i = 0; i < 6; i++) {
      millis = (millis << 8) | bytes[i];
    }
    return millis;
  }

  static String _encode(List<int> bytes) {
    BigInt value = BigInt.zero;
    for (final int byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    // 128 位补到 130 位（26 × 5），补的是高位 0
    value <<= 2;

    final List<String> chars = List<String>.filled(26, '0');
    final BigInt mask = BigInt.from(31);
    for (int i = 25; i >= 0; i--) {
      chars[i] = alphabet[(value & mask).toInt()];
      value >>= 5;
    }
    return chars.join();
  }

  static List<int>? _decode(String text) {
    BigInt value = BigInt.zero;
    for (int i = 0; i < text.length; i++) {
      final int index = alphabet.indexOf(text[i]);
      if (index < 0) {
        return null;
      }
      value = (value << 5) | BigInt.from(index);
    }
    // 去掉补的 2 位
    value >>= 2;
    final List<int> bytes = List<int>.filled(16, 0);
    for (int i = 15; i >= 0; i--) {
      bytes[i] = (value & BigInt.from(0xFF)).toInt();
      value >>= 8;
    }
    return bytes;
  }
}
