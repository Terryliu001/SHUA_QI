// 本地假 OpenAI 兼容服务：只用于真机联调，不联网、不花钱。
//
// 用法：
//   1. 在电脑上跑：`dart run tool/fake_llm_server.dart 8787`
//   2. 平板与电脑连同一网络时，端点点 `http://<电脑局域网 IP>:8787/v1`
//      或先 `adb reverse tcp:8787 tcp:8787`，端点用 `http://127.0.0.1:8787/v1`
//   3. 模型名随便填（如 `fake`），Key 随便填（如 `test`）。
//
// 支持三种请求：
//   - 普通对话：流式 SSE，回复里带 LaTeX，验证公式排版与半截公式；
//   - “先做一遍”：返回严格 JSON（answer/explanation）；
//   - “判我的作答”：返回严格 JSON（verdict/reason）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final int port = args.isEmpty ? 8787 : (int.tryParse(args.first) ?? 8787);
  final HttpServer server = await HttpServer.bind(
    InternetAddress.anyIPv4,
    port,
  );
  stdout.writeln('fake LLM on http://0.0.0.0:$port/v1');
  await for (final HttpRequest request in server) {
    unawaited(_handle(request));
  }
}

Future<void> _handle(HttpRequest request) async {
  try {
    if (request.method != 'POST' ||
        !request.uri.path.endsWith('/chat/completions')) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final String body = await utf8.decoder.bind(request).join();
    final Object? decoded = jsonDecode(body);
    final Map<String, Object?> payload = decoded is Map
        ? decoded.cast<String, Object?>()
        : <String, Object?>{};
    final List<Object?> rawMessages = payload['messages'] is List
        ? payload['messages']! as List<Object?>
        : <Object?>[];
    final String system = _textOfRole(rawMessages, 'system');
    final String user = _textOfRole(rawMessages, 'user');
    final bool stream = payload['stream'] == true;
    final String model = (payload['model'] as String?) ?? 'fake';

    if (system.contains('知识点归纳助手')) {
      stdout.writeln('request: tags (model=$model)');
      // 从 user 文本里按行抠 `id=<收藏id>`，按该行关键词给固定标签，
      // 便于真机看"按知识点分组"的效果（不同题落到不同组）。
      final Map<String, List<String>> tags = <String, List<String>>{};
      for (final String line in user.split('\n')) {
        final RegExpMatch? match = RegExp(
          r'id=([A-Za-z0-9_-]+)',
        ).firstMatch(line);
        if (match == null) {
          continue;
        }
        tags[match.group(1)!] = _fakeTagsFor(line);
      }
      await _json(request.response, <String, Object?>{
        'model': model,
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{'tags': tags}),
            },
          },
        ],
      });
      return;
    }
    if (system.contains('批改助手')) {
      stdout.writeln('request: grade (model=$model)');
      final bool wrong = user.contains('C') || user.contains('错误');
      await _json(request.response, <String, Object?>{
        'model': model,
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'verdict': wrong ? 'wrong' : 'correct',
                'reason': wrong ? '假服务器：作答与参考答案不一致。' : '假服务器：作答与参考答案一致。',
                'confidence': 0.86,
              }),
            },
          },
        ],
      });
      return;
    }
    if (system.contains('解题老师')) {
      stdout.writeln('request: solve (model=$model)');
      await _json(request.response, <String, Object?>{
        'model': model,
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'answer': r'$x=2$',
                'explanation':
                    r'假服务器解析：'
                    '\n'
                    r'1. 先把含 $x$ 的项移到一边；'
                    '\n'
                    r'2. 化简得 $x=2$。',
                'confidence': 0.9,
              }),
            },
          },
        ],
      });
      return;
    }

    stdout.writeln('request: chat stream=$stream (model=$model)');
    final List<String> chunks = user.toLowerCase().contains('code')
        ? <String>[
            '下面是示例：\n\n',
            r'```dart',
            '\n',
            r'final x = r"$y";',
            '\n',
            r'```',
            '\n\n',
            '可以点右上角复制。',
          ]
        : const <String>[
            '这道题的关键是先把含 \$x\$ 的项移到一边。\n\n',
            r'$$x^2-2x+1=0$$',
            '\n\n',
            r'配方后得到 $(x-1)^2=0$，',
            r'所以 $x=1$。',
          ];
    if (!stream) {
      await _json(request.response, <String, Object?>{
        'model': model,
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': chunks.join()},
          },
        ],
      });
      return;
    }
    final HttpResponse response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    response.bufferOutput = false;
    if (system.contains('深度思考')) {
      for (final String thought in <String>[
        '先看题面：含绝对值，先分情况讨论。\n',
        '再检查端点与连续性，最后给结论。\n',
      ]) {
        response.write(
          'data: ${jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'delta': <String, Object?>{'reasoning_content': thought},
              },
            ],
          })}\n\n',
        );
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    for (final String chunk in chunks) {
      response.write(
        'data: ${jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{'content': chunk},
            },
          ],
        })}\n\n',
      );
      await response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 260));
    }
    // 模拟 stream_options.include_usage：末尾一条 choices 为空、带 usage。
    response.write(
      'data: {"choices":[],"usage":{"prompt_tokens":321,"completion_tokens":87}}\n\n',
    );
    response.write('data: [DONE]\n\n');
    await response.close();
  } on Object catch (error) {
    stderr.writeln('fake LLM error: $error');
    try {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('{"error":{"message":"fake server error"}}');
      await request.response.close();
    } on Object {
      // 已经关闭就忽略。
    }
  }
}

Future<void> _json(HttpResponse response, Map<String, Object?> body) async {
  response.statusCode = HttpStatus.ok;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}

/// 假的知识点归纳：按"卷名/题型"关键词给固定标签。
///
/// 只用于真机联调，不追求准确；关键是"不同题落到不同组"能看清 UI。
List<String> _fakeTagsFor(String line) {
  final String lower = line.toLowerCase();
  final List<String> tags = <String>[];
  if (line.contains('数学分析') || lower.contains('lim') || line.contains('极限')) {
    tags.add('极限');
    tags.add('函数');
  }
  if (line.contains('英语') || line.contains('四级') || lower.contains('english')) {
    tags.add('英语词汇');
  }
  if (line.contains('改革') || line.contains('新时代') || line.contains('政治')) {
    tags.add('政治理论');
  }
  if (tags.isEmpty) {
    tags.add('假归纳');
  }
  return tags;
}

String _textOfRole(List<Object?> messages, String role) {
  final StringBuffer buffer = StringBuffer();
  for (final Object? item in messages) {
    if (item is! Map || item['role'] != role) {
      continue;
    }
    final Object? content = item['content'];
    if (content is String) {
      buffer.writeln(content);
    } else if (content is List) {
      for (final Object? part in content) {
        if (part is Map && part['type'] == 'text' && part['text'] is String) {
          buffer.writeln(part['text']);
        }
      }
    }
  }
  return buffer.toString();
}
