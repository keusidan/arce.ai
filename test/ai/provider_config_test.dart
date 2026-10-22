import 'dart:convert';

import 'package:arce_ai/ai/provider_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _openai = ProviderConfig(
  id: 'openai',
  label: 'OpenAI',
  baseUrl: 'https://api.openai.com/v1',
  models: [ModelConfig(id: 'gpt-4o-mini', name: 'GPT-4o mini')],
);

void main() {
  group('設定の読み書き', () {
    test('書き出した一覧をそのまま読み戻せる', () {
      final decoded = ProviderList.decode(ProviderList.encode([_openai]));
      expect(decoded, hasLength(1));
      expect(decoded.single.id, 'openai');
      expect(decoded.single.label, 'OpenAI');
      expect(decoded.single.baseUrl, 'https://api.openai.com/v1');
      expect(decoded.single.model, 'gpt-4o-mini');
      expect(decoded.single.models.single.name, 'GPT-4o mini');
      expect(decoded.single.supportsTools, isTrue);
    });

    test('モデルを複数持てて、パラメータとプロンプトも往復できる', () {
      final multi = _openai.copyWith(
        models: const [
          ModelConfig(id: 'gpt-4o-mini', name: 'mini'),
          ModelConfig(
            id: 'gpt-4o',
            name: '4o',
            params: {'temperature': 0.2, 'topP': 0.8, 'maxTokens': 4096},
            prompt: '短く答える',
          ),
        ],
      );
      final back = ProviderList.decode(ProviderList.encode([multi])).single;
      expect(back.models.map((m) => m.id), ['gpt-4o-mini', 'gpt-4o']);
      expect(back.models.last.param('temperature'), 0.2);
      expect(back.models.last.intParam('maxTokens'), 4096);
      expect(back.models.last.prompt, '短く答える');
      expect(back.modelById('gpt-4o')?.name, '4o');
    });

    test('モデルが無い古い保存は1件へ移行する', () {
      final old = jsonEncode([
        {
          'id': 'old',
          'label': 'Old',
          'baseUrl': 'https://old.example/v1',
          'model': 'old-model',
        },
      ]);
      final migrated = ProviderList.decode(old).single;
      expect(migrated.models.single.id, 'old-model');
      expect(migrated.models.single.name, 'old-model');
      expect(migrated.isComplete, isTrue);
    });

    test('上書きヘッダーと body を往復できる', () {
      final custom = _openai.copyWith(
        headers: {'X-Title': 'ARCE.AI'},
        body: {'reasoning_effort': 'low'},
        supportsTools: false,
      );
      final back = ProviderList.decode(ProviderList.encode([custom])).single;
      expect(back.headers, {'X-Title': 'ARCE.AI'});
      expect(back.body, {'reasoning_effort': 'low'});
      expect(back.supportsTools, isFalse);
    });

    test('APIキーは設定に含まれず、保存先の名前だけを持つ', () {
      expect(ProviderList.encode([_openai]), isNot(contains('key')));
      expect(_openai.keyRef, 'provider_key.openai');
    });

    test('壊れた保存でも落ちない', () {
      expect(ProviderList.decode('{'), isEmpty);
      expect(ProviderList.decode('42'), isEmpty);
      expect(ProviderList.decode(''), isEmpty);
      expect(ProviderList.decode(null), isEmpty);
      expect(ProviderList.decode('[1, "x", {"id": 5}]'), isEmpty);
    });

    test('id も baseUrl も無い項目は捨て、local という id も受け付けない', () {
      final raw = jsonEncode([
        {
          'id': 'ok',
          'label': 'OK',
          'baseUrl': 'https://x.example/v1',
          'models': [
            {'id': 'm'},
          ],
        },
        {'label': 'no id', 'baseUrl': 'https://y.example/v1', 'model': 'm'},
        {'id': 'no-url', 'label': 'no url', 'model': 'm'},
        {
          'id': 'local',
          'label': 'local',
          'baseUrl': 'https://z.example/v1',
          'model': 'm',
        },
        'not an object',
      ]);
      expect(ProviderList.decode(raw).map((p) => p.id), ['ok']);
    });

    test('種類の違う値は既定に戻す', () {
      final decoded = ProviderList.decode(
        jsonEncode([
          {
            'id': 'x',
            'label': 1,
            'baseUrl': 'https://x.example/v1',
            'model': 'm',
            'tools': 'yes',
            'headers': 3,
          },
        ]),
      ).single;
      expect(decoded.label, '');
      expect(decoded.supportsTools, isTrue);
      expect(decoded.headers, isEmpty);
      expect(decoded.body, isEmpty);
    });
  });

  group('id の付け方', () {
    test('名前から作り、重なれば番号を足す', () {
      expect(ProviderList.idFor('OpenAI', const []), 'openai');
      expect(ProviderList.idFor('Ollama (自宅)', const []), 'ollama');
      expect(ProviderList.idFor('OpenAI', const [_openai]), 'openai-2');
      // 別のつづりの id は重ならない
      expect(ProviderList.idFor('open ai', const [_openai]), 'open-ai');
      expect(
        ProviderList.idFor('open ai', const [
          _openai,
          ProviderConfig(
            id: 'open-ai',
            label: '',
            baseUrl: 'https://x.example/v1',
            models: [ModelConfig(id: 'm', name: 'm')],
          ),
        ]),
        'open-ai-2',
      );
    });

    test('名前が空でも使える id になる', () {
      expect(ProviderList.idFor('', const []), 'provider');
      expect(ProviderList.idFor('***', const []), 'provider');
    });
  });

  group('使える設定かどうか', () {
    test('URL・モデル・id が揃っていれば使える', () {
      expect(_openai.isComplete, isTrue);
      expect(_openai.copyWith(models: const []).isComplete, isFalse);
      expect(
        _openai.copyWith(baseUrl: 'api.openai.com/v1').isComplete,
        isFalse,
      );
    });
  });

  group('画像への対応', () {
    test('選んだ値は書き出して読み戻せ、選んでいなければ書き出さない', () {
      final set = _openai.copyWith(models: const [ModelConfig(id: 'm', name: 'm', vision: true)]);
      expect(ProviderList.decode(ProviderList.encode([set])).single.models.single.vision, isTrue);
      expect(ProviderList.encode([_openai]), isNot(contains('vision')));
      expect(ProviderList.decode(ProviderList.encode([_openai])).single.models.single.vision, isNull);
    });

    test('名前からの推測は、有名な系統だけ当てる', () {
      for (final id in ['gpt-4o', 'gpt-4.1-mini', 'claude-sonnet-4', 'gemini-2.5-flash', 'llava:13b', 'qwen2.5-vl-7b', 'meta-llama/llama-4-scout']) {
        expect(ModelConfig.guessVision(id), isTrue, reason: id);
      }
      for (final id in ['gpt-3.5-turbo', 'deepseek-chat', 'openai/gpt-oss-120b', 'qwen3-8b', 'llama-3.1-70b', 'o3-mini']) {
        expect(ModelConfig.guessVision(id), isFalse, reason: id);
      }
    });

    test('壊れた値は無かったことにして、推測に戻る', () {
      final m = ModelConfig.fromJson({'id': 'gpt-4o', 'name': 'x', 'vision': 'yes'});
      expect(m.vision, isNull);
      expect(m.supportsImages, isTrue);
    });
  });
}
