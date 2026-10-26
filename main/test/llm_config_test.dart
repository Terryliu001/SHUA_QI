import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';

void main() {
  test('端点自动补 /chat/completions', () {
    const LlmConfig config = LlmConfig(
      baseUrl: 'https://api.deepseek.com/v1',
      apiKey: 'k',
      model: 'deepseek-chat',
    );
    expect(
      config.chatCompletionsUrl,
      'https://api.deepseek.com/v1/chat/completions',
    );
  });

  test('末尾斜杠不会产生双斜杠', () {
    const LlmConfig config = LlmConfig(
      baseUrl: 'https://example.com/v1/',
      apiKey: 'k',
      model: 'm',
    );
    expect(
      config.chatCompletionsUrl,
      'https://example.com/v1/chat/completions',
    );
  });

  test('已经填完整路径时原样使用', () {
    const LlmConfig config = LlmConfig(
      baseUrl: 'https://example.com/v1/chat/completions',
      apiKey: 'k',
      model: 'm',
    );
    expect(
      config.chatCompletionsUrl,
      'https://example.com/v1/chat/completions',
    );
  });

  test('配置完整性校验', () {
    expect(LlmConfig.empty.validationError(), '请填写端点地址');
    expect(
      const LlmConfig(
        baseUrl: 'ftp://x',
        apiKey: 'k',
        model: 'm',
      ).validationError(),
      '端点要以 http:// 或 https:// 开头',
    );
    expect(
      const LlmConfig(
        baseUrl: 'https://x',
        apiKey: '',
        model: 'm',
      ).validationError(),
      '请填写 API Key',
    );
    expect(
      const LlmConfig(
        baseUrl: 'https://x',
        apiKey: 'k',
        model: '',
      ).validationError(),
      '请填写模型名',
    );
    expect(
      const LlmConfig(
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
        timeout: Duration(seconds: 2),
      ).validationError(),
      '超时需在 5–300 秒之间',
    );
    expect(
      const LlmConfig(
        baseUrl: 'http://192.168.1.2:8787/v1',
        apiKey: 'k',
        model: 'm',
      ).validationError(),
      isNull,
    );
  });

  test('Key 脱敏只保留末 4 位', () {
    expect(const LlmConfig(apiKey: 'sk-1234567890abcd').maskedKey, '••••abcd');
    expect(const LlmConfig(apiKey: 'short').maskedKey, '••••');
    expect(const LlmConfig().maskedKey, '未保存');
  });

  test('相等性用于客户端复用', () {
    const LlmConfig a = LlmConfig(
      baseUrl: 'https://x/v1',
      apiKey: 'k',
      model: 'm',
    );
    const LlmConfig b = LlmConfig(
      baseUrl: 'https://x/v1',
      apiKey: 'k',
      model: 'm',
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == b.copyWith(model: 'n'), isFalse);
  });
}
