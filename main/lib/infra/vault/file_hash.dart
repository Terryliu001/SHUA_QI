import 'dart:io';

import 'package:crypto/crypto.dart';

/// 流式计算文件的 sha1（十六进制小写）。
///
/// **必须流式**：20MB 的卷用 `readAsBytes()` 会瞬间吃掉 20MB 堆内存，
/// 而导入过程同时还要渲染缩略图，很容易被系统直接杀掉。
Future<String> sha1OfFile(File file) async {
  final Digest digest = await sha1.bind(file.openRead()).first;
  return digest.toString();
}
