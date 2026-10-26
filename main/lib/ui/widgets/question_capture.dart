import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/ui/reader/answer_crop_renderer.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/widgets/image_viewer.dart';

/// 与保存图片同一个原生通道（相册）。
const MethodChannel _mediaChannel = MethodChannel('com.shuaqi.shuaqi/media');

/// 把一道题的**题面**渲染成 PNG 字节（不含笔迹）。
///
/// 为什么要单独一个函数：阅读器（长按题面预览）与答题卡（长按题面图）
/// 要的是同一张图——"这张题我想发给老师 / AI"。两处各写一份就会漂移
/// （2026-10-26 用户第 13 条）。
Future<Uint8List?> renderQuestionStemPng({
  required PageImageCache cache,
  required WbPage page,
  required RegionRect rect,
}) {
  return renderAnswerCropPng(
    cache: cache,
    page: page,
    rect: rect,
    doc: InkDoc.empty,
  );
}

/// 题目图片的文件名：`shuaqi_12_abc123.png`。
String questionImageFileName(String label, String questionId) {
  final String safe = label.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5-]'), '_');
  return 'shuaqi_${safe}_${questionId.substring(0, 6)}.png';
}

/// 把题面图存到相册。返回一句给用户看的结果（成功/失败都返回文字）。
///
/// [fallback] 是"原生通道不可用"时的兜底（阅读器会落应用导出目录）；
/// 没有兜底就如实说失败——不做假成功。
Future<String> saveQuestionImageToGallery({
  required PageImageCache cache,
  required WbPage page,
  required RegionRect rect,
  required String fileName,
  Future<String?> Function(Uint8List bytes)? fallback,
}) async {
  final Uint8List? bytes = await renderQuestionStemPng(
    cache: cache,
    page: page,
    rect: rect,
  );
  if (bytes == null) {
    return '题目图片生成失败';
  }
  try {
    await _mediaChannel.invokeMethod<String>('saveImage', <String, Object>{
      'bytes': bytes,
      'name': fileName,
    });
    return '已保存到相册';
  } on PlatformException {
    // 通道不可用/被拒绝：交给调用方的兜底。
  } on MissingPluginException {
    // 同上。
  }
  if (fallback != null) {
    return await fallback(bytes) ?? '保存失败，请稍后再试';
  }
  return '保存失败（系统相册不可用）';
}

/// 长按题面图时的侧边浮窗动作（阅读器与答题卡共用）。
///
/// 2026-10-26 用户第 13 条：长按不要直接保存，要贴着图给一个浮窗，
/// 把"存哪一种 / 存好了没有"说清楚——与阅读器里的题面预览同一套交互。
List<ImageAction> questionImageActions({
  required Future<String?> Function() onSave,
}) {
  return <ImageAction>[
    ImageAction(
      label: '保存到相册',
      subtitle: '题面原图，适合发给老师或 AI',
      icon: Icons.download_outlined,
      onSelected: onSave,
    ),
  ];
}
