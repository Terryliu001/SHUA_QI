import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ai/chat.dart';

/// 把图片压到模型能接受的尺寸，并包成 [AiImageAttachment]。
///
/// 为什么要自己做：
/// - 平板截图/相册照片动辄 2000–3000px，直接 Base64 会让请求体到几 MB；
/// - 开发指南 07 的成本硬限制是**长边 ≤1024**；
/// - 缩放失败不能阻断发送：退回原图，让模型/服务端去报错。
Future<AiImageAttachment?> prepareAiImage({
  required Uint8List bytes,
  required AiImageKind kind,
  required String label,
  int maxEdge = 1024,
}) async {
  if (bytes.isEmpty) {
    return null;
  }
  ui.Image? image;
  ui.Image? scaled;
  ui.Picture? picture;
  try {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    image = frame.image;
    final int width = image.width;
    final int height = image.height;
    if (width <= 0 || height <= 0) {
      return AiImageAttachment(kind: kind, label: label, bytes: bytes);
    }
    final int longEdge = width > height ? width : height;
    // 即使是小图也重新编码成 PNG：用户相册里可能是 JPEG，而
    // OpenAI 兼容协议的 data URL 这里统一写 `image/png`。不转的话，
    // 少数端点会按 MIME 解析失败。
    final double scale = longEdge <= maxEdge ? 1 : maxEdge / longEdge;
    final int outWidth = (width * scale).round().clamp(1, maxEdge);
    final int outHeight = (height * scale).round().clamp(1, maxEdge);
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    picture = recorder.endRecording();
    scaled = await picture.toImage(outWidth, outHeight);
    final ByteData? data = await scaled.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (data == null) {
      return AiImageAttachment(kind: kind, label: label, bytes: bytes);
    }
    return AiImageAttachment(
      kind: kind,
      label: label,
      bytes: data.buffer.asUint8List(),
      width: outWidth.toDouble(),
      height: outHeight.toDouble(),
    );
  } on Object {
    return AiImageAttachment(
      kind: kind,
      label: label,
      bytes: bytes,
      width: 0,
      height: 0,
    );
  } finally {
    scaled?.dispose();
    image?.dispose();
    picture?.dispose();
  }
}

/// 从系统相册/文件选择器挑一张图。用户取消返回 null。
///
/// file_picker 13 是静态 API；Android 走系统照片选择器，不需要存储权限。
Future<AiImageAttachment?> pickAiImageFromDevice({
  String label = '我上传的图片',
}) async {
  List<PlatformFile> picked = const <PlatformFile>[];
  try {
    picked = await FilePicker.pickFiles(type: FileType.image);
  } on Object {
    return null;
  }
  if (picked.isEmpty) {
    return null;
  }
  final PlatformFile file = picked.first;
  Uint8List? bytes;
  try {
    bytes = await file.readAsBytes();
  } on Object {
    bytes = null;
  }
  if (bytes == null || bytes.isEmpty) {
    return null;
  }
  return prepareAiImage(bytes: bytes, kind: AiImageKind.user, label: label);
}
