import 'package:arce_ai/ai/model_hints.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('モデルの系統', () {
    test('名前から DeepSeek と GLM を見分ける', () {
      for (final id in ['deepseek-ai/DeepSeek-V4.1-Flash-1017', 'deepseek-v4-flash', 'DeepSeek-V4-Pro-0813', 'deepseek-chat']) {
        expect(ModelHints.familyOf(id), ModelFamily.deepseek, reason: id);
      }
      for (final id in ['zai-org/GLM-5.3', 'z-ai/glm-5.2', 'glm-4.6', 'GLM-5-FP8']) {
        expect(ModelHints.familyOf(id), ModelFamily.glm, reason: id);
      }
      for (final id in ['gpt-4o', 'qwen3-8b', 'claude-sonnet-4', 'llama-3.1-70b', 'glmnet-classifier']) {
        expect(ModelHints.familyOf(id), ModelFamily.other, reason: id);
      }
    });

    test('推奨は、モデルカードのあるバージョンにだけ出す', () {
      final deepseek = ModelHints.of('deepseek-ai/DeepSeek-V4.1-Flash-1017')!;
      expect(deepseek.temperature, 1.0);
      expect(deepseek.topP, 1.0);
      expect(deepseek.maxTokens, 262144, reason: 'the card says max_tokens ≥ 256K');
      expect(deepseek.contextTokens, 1048576, reason: 'the card says 1M');

      final glm = ModelHints.of('zai-org/GLM-5.3')!;
      expect(glm.temperature, 1.0);
      expect(glm.topP, 0.95);
      expect(glm.maxTokens, 128000);

      expect(ModelHints.of('deepseek-chat'), isNull, reason: 'a version the cards do not describe');
      expect(ModelHints.of('glm-4.6'), isNull);
      expect(ModelHints.of('gpt-4o'), isNull);
    });
  });

  group('最大トークンの決め方', () {
    int resolve({
      int? model,
      bool userSet = false,
      int requested = 2048,
      ModelHint? hint,
      int? maxOutput,
      int? context,
      int prompt = 1000,
    }) => ModelHints.resolveMaxTokens(
      modelSetting: model,
      requestedIsUserSet: userSet,
      requested: requested,
      hint: hint,
      maxOutput: maxOutput,
      context: context,
      promptTokens: prompt,
    );
    final hint = ModelHints.of('deepseek-v4-flash');

    test('強い順：モデルの設定 > 設定画面でユーザーが決めた値 > 公式の推奨 > アプリの既定', () {
      expect(resolve(model: 5000, userSet: true, requested: 3000, hint: hint), 5000);
      expect(resolve(userSet: true, requested: 3000, hint: hint), 3000, reason: 'the user set it in the settings');
      expect(resolve(requested: 2048, hint: hint), 262144, reason: '2048 is only the app default, so the recommendation wins');
      expect(resolve(requested: 2048), 2048, reason: 'a model without a recommendation keeps the default');
    });

    test('モデルが返せる最大より大きくしない', () {
      expect(resolve(model: 500000, maxOutput: 65536), 65536);
      expect(resolve(hint: hint, maxOutput: 100000), 100000, reason: 'the recommendation is cut to what the model can return');
      expect(resolve(model: 1000, maxOutput: 65536), 1000);
    });

    test('入力で埋まった分を引く。入力と出力が文脈に収まらない要求は、プロバイダに断られるため', () {
      expect(resolve(model: 50000, context: 8192, prompt: 1000), 8192 - 1000 - 512);
      expect(resolve(model: 4000, context: 131072, prompt: 1000), 4000, reason: 'it fits as it is');
      expect(resolve(model: 50000, context: 8192, prompt: 8000), 256, reason: 'almost no room: a short answer, never less');
      expect(resolve(hint: hint, prompt: 500000), 262144, reason: 'the recommended 256K still fits after a 500K prompt in a 1M window');
      expect(resolve(hint: hint, prompt: 900000), 1048576 - 900000 - 512, reason: 'but not after a 900K prompt');
    });

    test('ユーザーが決めた小さい値は、そのまま使う', () {
      expect(resolve(model: 128), 128);
      expect(resolve(userSet: true, requested: 100), 100);
    });
  });

  test('トークン数の見積もり：日本語は1文字ほど、英語は3文字で1トークンほど', () {
    expect(ModelHints.estimateTokens('こんにちは'), 5);
    expect(ModelHints.estimateTokens('hello world'), 4);
    expect(ModelHints.estimateTokens(''), 0);
  });
}
