import 'package:flutter/material.dart';

import 'ink_spike_page.dart';

/// T0.2 spike 的独立入口。
///
/// 用法（不污染 lib/main.dart，跑完连目录一起删）：
///   flutter run --profile -t spikes/ink_spike/main.dart
///   flutter build apk --profile -t spikes/ink_spike/main.dart
void main() {
  runApp(const InkSpikeApp());
}

class InkSpikeApp extends StatelessWidget {
  const InkSpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'T0.2 书写 spike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1F6FEB),
        useMaterial3: true,
      ),
      home: const InkSpikePage(),
    );
  }
}
