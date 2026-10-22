import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 分层约束（规格 §4.1）。用测试守住，而不是写进文档指望大家记得。
///
/// 规则本身很短，但它拦的是最贵的一类错误：`domain` 里悄悄 `import 'package:flutter/material.dart'`
/// 之后，所有几何/判题逻辑就再也没法脱离 Flutter 做单测，而且会引着 UI 概念往下沉。
void main() {
  test('domain 必须是纯 Dart：不得 import Flutter / dart:io / dart:ui', () {
    final List<String> violations = <String>[];
    for (final File file in _dartFiles('lib/domain')) {
      for (final String uri in _importsOf(file)) {
        if (uri.startsWith('package:flutter/') ||
            uri == 'dart:io' ||
            uri == 'dart:ui' ||
            uri == 'dart:html') {
          violations.add('${_relative(file.path)} → $uri');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: 'domain 层出现了平台依赖：\n${violations.join('\n')}',
    );
  });

  test('domain 不得反向依赖 app / infra / ui / state', () {
    final List<String> violations = <String>[];
    for (final File file in _dartFiles('lib/domain')) {
      for (final String uri in _importsOf(file)) {
        if (_startsWithAny(uri, <String>[
          'package:shuaqi/app/',
          'package:shuaqi/infra/',
          'package:shuaqi/ui/',
          'package:shuaqi/state/',
        ])) {
          violations.add('${_relative(file.path)} → $uri');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '依赖方向反了（只能 ui → state → domain，app → infra → domain）：\n'
          '${violations.join('\n')}',
    );
  });

  test('infra 与 app 不得 import Material / Widgets / Cupertino', () {
    final List<String> violations = <String>[];
    for (final String layer in <String>['lib/infra', 'lib/app']) {
      for (final File file in _dartFiles(layer)) {
        for (final String uri in _importsOf(file)) {
          if (_startsWithAny(uri, <String>[
            'package:flutter/material.dart',
            'package:flutter/widgets.dart',
            'package:flutter/cupertino.dart',
            'package:flutter/src/',
          ])) {
            violations.add('${_relative(file.path)} → $uri');
          }
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '下层不许持有 Widget（§4.2 各模块的禁止列）：\n${violations.join('\n')}',
    );
  });

  test('只有 ui / state / main 允许 import Material', () {
    final List<String> offenders = <String>[];
    for (final File file in _dartFiles('lib')) {
      final String path = _relative(file.path).replaceAll('\\', '/');
      if (path.startsWith('lib/ui/') ||
          path.startsWith('lib/state/') ||
          path == 'lib/main.dart') {
        continue;
      }
      for (final String uri in _importsOf(file)) {
        if (uri.startsWith('package:flutter/material.dart') ||
            uri.startsWith('package:flutter/widgets.dart')) {
          offenders.add('$path → $uri');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Widget 只允许出现在 ui / state / main：\n${offenders.join('\n')}',
    );
  });
}

Iterable<File> _dartFiles(String directory) {
  final Directory dir = Directory(directory);
  if (!dir.existsSync()) {
    return const <File>[];
  }
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((File file) => file.path.endsWith('.dart'))
      .toList();
}

final RegExp _importPattern = RegExp(
  r'''^\s*import\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

List<String> _importsOf(File file) {
  final String source = file.readAsStringSync();
  return _importPattern
      .allMatches(source)
      .map((RegExpMatch match) => match.group(1) ?? '')
      .where((String uri) => uri.isNotEmpty)
      .toList(growable: false);
}

bool _startsWithAny(String value, List<String> prefixes) {
  for (final String prefix in prefixes) {
    if (value.startsWith(prefix)) {
      return true;
    }
  }
  return false;
}

String _relative(String path) => path.replaceAll('\\', '/');
