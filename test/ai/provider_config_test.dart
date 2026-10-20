import 'dart:convert';

import 'package:arce_ai/ai/provider_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _openai = ProviderConfig(
  id: 'openai',
  label: 'OpenAI',
  baseUrl: 'https://api.openai.com/v1',
  model: 'gpt-4o-mini',
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
      expect(decoded.single.supportsTools, isTrue);
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
        {'id': 'ok', 'label': 'OK', 'baseUrl': 'https://x.example/v1', 'model': 'm'},
        {'label': 'no id', 'baseUrl': 'https://y.example/v1', 'model': 'm'},
        {'id': 'no-url', 'label': 'no url', 'model': 'm'},
        {'id': 'local', 'label': 'local', 'baseUrl': 'https://z.example/v1', 'model': 'm'},
        'not an object',
      ]);
      expect(ProviderList.decode(raw).map((p) => p.id), ['ok']);
    });

    test('種類の違う値は既定に戻す', () {
      final decoded = ProviderList.decode(
        jsonEncode([
          {'id': 'x', 'label': 1, 'baseUrl': 'https://x.example/v1', 'model': 'm', 'tools': 'yes', 'headers': 3},
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
          ProviderConfig(id: 'open-ai', label: '', baseUrl: 'https://x.example/v1', model: 'm'),
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
      expect(_openai.copyWith(model: ' ').isComplete, isFalse);
      expect(_openai.copyWith(baseUrl: 'api.openai.com/v1').isComplete, isFalse);
    });
  });
}
