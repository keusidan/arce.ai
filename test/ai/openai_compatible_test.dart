import 'dart:convert';
import 'dart:typed_data';

import 'package:arce_ai/ai/openai_compatible.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/core/attachments.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A server that answers one chat request with the given SSE chunks.
OpenAiCompatibleProvider providerWith(
  List<String> chunks, {
  int status = 200,
  String errorBody = '',
  void Function(http.BaseRequest request)? onRequest,
  String body = '',
}) {
  final client = MockClient.streaming((request, _) async {
    onRequest?.call(request);
    if (status != 200) return http.StreamedResponse(Stream.value(utf8.encode(errorBody)), status, request: request);
    return http.StreamedResponse(
      Stream.fromIterable(chunks.map(utf8.encode)),
      200,
      headers: const {'content-type': 'text/event-stream'},
      request: request,
    );
  });
  return OpenAiCompatibleProvider(
    id: 'test',
    label: 'テスト',
    baseUrl: 'https://api.example/v1/',
    model: 'test-model',
    apiKey: 'sk-test',
    client: client,
    body: body.isEmpty ? const {} : jsonDecode(body) as Map<String, Object?>,
  );
}

String event(Map<String, Object?> json) => 'data: ${jsonEncode(json)}\n\n';

String textEvent(String text) => event({
      'choices': [
        {
          'delta': {'content': text},
        },
      ],
    });

void main() {
  const request = AiRequest(
    messages: [
      AiMessage(AiRole.system, text: 'あなたは助手です。'),
      AiMessage(AiRole.user, text: 'こんにちは'),
    ],
  );

  group('本文と終わり方', () {
    test('本文を順に流し、使い方と stop を最後に返す', () async {
      final provider = providerWith([
        textEvent('こん'),
        textEvent('にちは'),
        event({
          'choices': [
            {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
          ],
          'usage': {'prompt_tokens': 12, 'completion_tokens': 3},
        }),
        'data: [DONE]\n\n',
      ]);

      final deltas = await provider.stream(request).toList();

      expect(
        [for (final d in deltas) if (d is TextDelta) d.text],
        ['こん', 'にちは'],
      );
      final usage = deltas.whereType<UsageDelta>().single;
      expect(usage.promptTokens, 12);
      expect(usage.completionTokens, 3);
      expect(deltas.last, isA<StopDelta>());
      expect((deltas.last as StopDelta).reason, FinishReason.eog);
    });

    test('考えた過程は ReasoningDelta として分ける', () async {
      final provider = providerWith([
        event({
          'choices': [
            {
              'delta': {'reasoning_content': 'まず考える'},
            },
          ],
        }),
        textEvent('答え'),
      ]);

      final deltas = await provider.stream(request).toList();
      final reasoning = deltas.whereType<ReasoningDelta>().single;
      expect(reasoning.text, 'まず考える');
      expect([for (final d in deltas) if (d is TextDelta) d.text], ['答え']);
    });

    test('トークン上限で切れたら length として返す', () async {
      final provider = providerWith([
        textEvent('途中'),
        event({
          'choices': [
            {'delta': <String, Object?>{}, 'finish_reason': 'length'},
          ],
        }),
      ]);

      final deltas = await provider.stream(request).toList();
      expect((deltas.last as StopDelta).reason, FinishReason.length);
    });

    test('イベントが chunk の境目で切れても読める', () async {
      final whole = textEvent('こんにちは') +
          event({
            'choices': [
              {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
            ],
          });
      // a network chunk boundary in the middle of the JSON
      final provider = providerWith([whole.substring(0, 20), whole.substring(20)]);

      final deltas = await provider.stream(request).toList();
      expect([for (final d in deltas) if (d is TextDelta) d.text], ['こんにちは']);
      expect(deltas.last, isA<StopDelta>());
    });
  });

  group('道具の呼び出し', () {
    test('分割されて届いた引数を組み立て、完成した時点で1つ返す', () async {
      final provider = providerWith([
        event({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'function': {'name': 'web_search', 'arguments': '{"que'},
                  },
                ],
              },
            },
          ],
        }),
        event({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': 'ry":"天気"}'},
                  },
                ],
              },
            },
          ],
        }),
        event({
          'choices': [
            {'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
          ],
        }),
      ]);

      final calls = (await provider.stream(request).toList()).whereType<ToolCallDelta>().toList();
      expect(calls, hasLength(1));
      expect(calls.single.name, 'web_search');
      expect(calls.single.id, 'call_1');
      expect(jsonDecode(calls.single.argumentsJson), {'query': '天気'});
    });

    test('2つ同時に呼ばれたら index の順に返す', () async {
      final provider = providerWith([
        event({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 1,
                    'id': 'b',
                    'function': {'name': 'get_time', 'arguments': '{}'},
                  },
                  {
                    'index': 0,
                    'id': 'a',
                    'function': {'name': 'get_weather', 'arguments': '{"city":"東京"}'},
                  },
                ],
              },
            },
          ],
        }),
        event({
          'choices': [
            {'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
          ],
        }),
      ]);

      final calls = (await provider.stream(request).toList()).whereType<ToolCallDelta>().toList();
      expect([for (final c in calls) c.name], ['get_weather', 'get_time']);
    });
  });

  group('送る内容', () {
    test('モデル・履歴・道具の定義を OpenAI の形で送る', () async {
      Map<String, Object?>? sent;
      final provider = providerWith(
        [textEvent('ok')],
        onRequest: (request) => sent = jsonDecode((request as http.Request).body) as Map<String, Object?>,
      );

      await provider
          .stream(const AiRequest(
            messages: [
              AiMessage(AiRole.system, text: 'system'),
              AiMessage(AiRole.user, text: 'これは何'),
              AiMessage(AiRole.assistant, toolCalls: [
                ToolCallDelta(id: 'call_1', name: 'get_time', argumentsJson: '{"timezone":"Asia/Tokyo"}'),
              ]),
              AiMessage(AiRole.tool, text: '2026-10-20T22:00:00Z', toolCallId: 'call_1'),
            ],
            tools: [
              AiToolSpec(
                name: 'get_time',
                description: 'いまの時刻',
                parameters: {
                  'type': 'object',
                  'properties': {
                    'timezone': {'type': 'string'},
                  },
                },
              ),
            ],
          ))
          .toList();

      expect(sent!['model'], 'test-model');
      expect(sent!['stream'], isTrue);
      final messages = (sent!['messages'] as List).cast<Map<String, Object?>>();
      expect([for (final m in messages) m['role']], ['system', 'user', 'assistant', 'tool']);
      expect(messages.last['tool_call_id'], 'call_1');
      final calls = (messages[2]['tool_calls'] as List).cast<Map<String, Object?>>();
      expect((calls.single['function'] as Map)['name'], 'get_time');
      final tools = (sent!['tools'] as List).cast<Map<String, Object?>>();
      expect((tools.single['function'] as Map)['name'], 'get_time');
      expect(sent!.containsKey('stream_options'), isTrue);
    });

    test('接続先の違いはヘッダーと body の上書きで吸収する', () async {
      http.BaseRequest? seen;
      final provider = providerWith(
        [textEvent('ok')],
        body: '{"thinking":{"type":"enabled"}}',
        onRequest: (request) => seen = request,
      );

      await provider.stream(request).toList();

      final sent = jsonDecode((seen as http.Request).body) as Map<String, Object?>;
      expect(sent['thinking'], {'type': 'enabled'});
      expect(sent['model'], 'test-model', reason: 'overrides add fields, they do not replace the request');
    });

    test('道具を送らない設定なら tools を付けない', () async {
      Map<String, Object?>? sent;
      final client = MockClient.streaming((request, _) async {
        sent = jsonDecode((request as http.Request).body) as Map<String, Object?>;
        return http.StreamedResponse(Stream.value(utf8.encode(textEvent('ok'))), 200, request: request);
      });
      final provider = OpenAiCompatibleProvider(
        id: 'local',
        label: 'ローカル互換',
        baseUrl: 'http://127.0.0.1:11434/v1',
        model: 'qwen',
        client: client,
        supportsTools: false,
      );

      await provider
          .stream(const AiRequest(
            messages: [AiMessage(AiRole.user, text: 'hi')],
            tools: [
              AiToolSpec(name: 'x', description: '', parameters: {'type': 'object'}),
            ],
          ))
          .toList();

      expect(sent!.containsKey('tools'), isFalse);
    });
  });

  group('失敗', () {
    test('キーが拒否されたら、その旨を返す', () async {
      final provider = providerWith(
        const [],
        status: 401,
        errorBody: jsonEncode({
          'error': {'message': 'Incorrect API key provided'},
        }),
      );

      await expectLater(
        provider.stream(request).toList(),
        throwsA(isA<AiProviderException>().having(
          (e) => e.message,
          'message',
          allOf(contains('APIキー'), contains('Incorrect API key')),
        )),
      );
    });

    test('接続先が無いときは URL を疑うよう伝える', () async {
      final provider = providerWith(const [], status: 404, errorBody: 'not found');

      await expectLater(
        provider.stream(request).toList(),
        throwsA(isA<AiProviderException>().having((e) => e.message, 'message', contains('URL'))),
      );
    });

    test('接続確認は /models を叩く', () async {
      late Uri seen;
      final client = MockClient((request) async {
        seen = request.url;
        return http.Response('{"data":[]}', 200);
      });
      final provider = OpenAiCompatibleProvider(
        id: 'test',
        label: 'テスト',
        baseUrl: 'https://api.example/v1',
        model: 'm',
        apiKey: 'sk-test',
        client: client,
      );

      await provider.verify();
      expect(seen.toString(), 'https://api.example/v1/models');
    });
  });

  group('思考の項目', () {
    test('モデルの項目は本体に入り、提供元の上書きがそれより強い', () async {
      Map<String, Object?>? sent;
      final provider = providerWith(
        [textEvent('ok'), 'data: [DONE]\n\n'],
        body: jsonEncode({'reasoning_effort': 'low', 'top_k': 5}),
        onRequest: (r) => sent = jsonDecode((r as http.Request).body) as Map<String, Object?>,
      );
      await provider
          .stream(const AiRequest(
            messages: [AiMessage(AiRole.user, text: 'こんにちは')],
            extraBody: {
              'thinking': {'type': 'enabled'},
              'reasoning_effort': 'max',
            },
          ))
          .toList();
      expect(sent!['thinking'], {'type': 'enabled'});
      expect(sent!['reasoning_effort'], 'low', reason: 'the provider\'s own override comes last');
      expect(sent!['top_k'], 5);
    });
  });

  group('モデル一覧', () {
    test('上限と画像対応を、提供元の一覧から読む。IDの順に並べる', () async {
      final provider = providerWith([
        jsonEncode({
          'data': [
            {'id': 'zeta', 'context_length': 8192},
            {
              'id': 'alpha',
              'context_length': 1048576,
              'architecture': {'input_modalities': ['text', 'image']},
              'top_provider': {'max_completion_tokens': 262144},
            },
          ],
        }),
      ]);
      final infos = await provider.fetchModelInfos();
      expect([for (final i in infos) i.id], ['alpha', 'zeta']);
      expect(infos.first.contextTokens, 1048576);
      expect(infos.first.maxOutputTokens, 262144);
      expect(infos.first.vision, isTrue);
      expect(infos.last.maxOutputTokens, isNull);
    });

    test('名前だけの一覧は、これまでどおり listModels で読める', () async {
      final provider = providerWith([jsonEncode({'data': [{'id': 'b'}, {'id': 'a'}]})]);
      expect(await provider.listModels(), ['a', 'b']);
    });

    test('読めない応答と、エラーの応答は、そのまま見せられる理由で失敗する', () async {
      await expectLater(providerWith(['<html>']).fetchModelInfos(), throwsA(isA<AiProviderException>()));
      await expectLater(providerWith(const [], status: 401, errorBody: '{}').fetchModelInfos(), throwsA(isA<AiProviderException>()));
    });
  });

  group('画像', () {
    test('画像つきのメッセージは、本文と画像の並びとして送る', () async {
      Map<String, Object?>? sent;
      final provider = providerWith(
        [textEvent('ok'), 'data: [DONE]\n\n'],
        onRequest: (r) => sent = jsonDecode((r as http.Request).body) as Map<String, Object?>,
      );
      final image = ImageData('image/png', Uint8List.fromList([1, 2, 3]));
      await provider
          .stream(AiRequest(messages: [AiMessage(AiRole.user, text: 'これは何？', images: [image])]))
          .toList();
      final content = ((sent!['messages']! as List).single as Map)['content'] as List;
      expect(content[0], {'type': 'text', 'text': 'これは何？'});
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,AQID'},
      });
    });

    test('画像のないメッセージは、これまでどおり文字列のまま送る', () async {
      Map<String, Object?>? sent;
      final provider = providerWith(
        [textEvent('ok'), 'data: [DONE]\n\n'],
        onRequest: (r) => sent = jsonDecode((r as http.Request).body) as Map<String, Object?>,
      );
      await provider.stream(request).toList();
      expect(((sent!['messages']! as List).last as Map)['content'], 'こんにちは');
    });

    test('画像に対応するかは、モデルの設定、なければ名前から決まる', () {
      OpenAiCompatibleProvider with_(String model, {ModelConfig? config}) => OpenAiCompatibleProvider(
            id: 't',
            label: 't',
            baseUrl: 'https://x/v1',
            model: model,
            modelConfig: config,
          );
      expect(with_('gpt-4o-mini').capabilities.vision, isTrue);
      expect(with_('qwen2.5-vl-7b').capabilities.vision, isTrue);
      expect(with_('deepseek-chat').capabilities.vision, isFalse);
      expect(with_('gpt-oss-120b').capabilities.vision, isFalse);
      // the user's choice wins over the guess, both ways
      expect(with_('gpt-4o', config: const ModelConfig(id: 'gpt-4o', name: 'x', vision: false)).capabilities.vision, isFalse);
      expect(with_('my-model', config: const ModelConfig(id: 'my-model', name: 'x', vision: true)).capabilities.vision, isTrue);
    });
  });
}
