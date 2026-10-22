import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/util/ulid.dart';

void main() {
  group('ULID', () {
    test('长度 26，且只用 Crockford 字母表', () {
      final String id = Ulid.next();
      expect(id.length, 26);
      for (final int code in id.codeUnits) {
        expect(Ulid.alphabet.contains(String.fromCharCode(code)), isTrue);
      }
      // Crockford 排除了 I / L / O / U
      expect(id.contains('I'), isFalse);
      expect(id.contains('L'), isFalse);
      expect(id.contains('O'), isFalse);
      expect(id.contains('U'), isFalse);
    });

    test('默认用大写字母（数据库里可比较、可排序）', () {
      final String id = Ulid.next();
      expect(id, id.toUpperCase());
    });

    test('时间不同则字符串序与时间序一致', () {
      final DateTime earlier = DateTime.utc(2026, 10, 22, 4, 0, 0);
      final DateTime later = DateTime.utc(2026, 10, 22, 5, 0, 0);
      final String a = Ulid.next(earlier);
      final String b = Ulid.next(later);
      expect(a.compareTo(b) < 0, isTrue, reason: 'ULID 必须按时间单调');
    });

    test('能从 ULID 取回时间戳', () {
      final DateTime at = DateTime.utc(2026, 10, 22, 6, 30, 15);
      final String id = Ulid.next(at);
      expect(Ulid.timestampOf(id), at.millisecondsSinceEpoch);
    });

    test('同一毫秒内批量生成不重复', () {
      final DateTime at = DateTime.utc(2026, 10, 22, 7);
      final Set<String> ids = <String>{
        for (int i = 0; i < 2000; i++) Ulid.next(at),
      };
      expect(ids.length, 2000);
    });

    test('非法输入解析返回 null，不抛', () {
      expect(Ulid.timestampOf('too-short'), isNull);
      // I 不在 Crockford 字母表里
      expect(Ulid.timestampOf(List<String>.filled(26, 'I').join()), isNull);
      // 全 0 是合法的 ULID（1970-01-01），时间戳应为 0
      expect(Ulid.timestampOf(List<String>.filled(26, '0').join()), 0);
    });
  });
}
