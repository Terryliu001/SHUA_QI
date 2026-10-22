import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pdf_spike_page.dart';

/// T0.4 的独立入口。
///
/// pdfrx 有个必须做的初始化：直接调用 `PdfDocument` API 时（不经过 PdfViewer 组件），
/// 必须先 `await pdfrxFlutterInitialize()`，否则底层 entry function 未注册。
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  runApp(const PdfSpikeApp());
}

class PdfSpikeApp extends StatelessWidget {
  const PdfSpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'T0.4 PDF spike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1F6FEB),
        useMaterial3: true,
      ),
      home: const PdfSpikePage(),
    );
  }
}
