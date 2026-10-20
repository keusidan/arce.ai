import 'dart:convert';

import 'package:arce_ai/ai/cloud_engine.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:arce_ai/core/stream_segmenter.dart' hide ToolCallDelta;
import 'package:flutter_test/flutter_test.dart';

const _sampling = SamplingParams(temperature: 0.3, topP: 0.9, topK: 20, minP: 0);

GenerateRequest _request({int maxTokens = 256}) => GenerateRequest(
      prompt: ChatMlPromptBuilder.build(const [UserTurn('こんにちは')], const [], null, false),
      toolCallSchema: null,
      thinking: false,
      maxTokens: maxTokens,
      sampling: _sampling,
    );

/// A provider that streams a fixed list and remembers the request it was given.
class _FixedProvider implements AiProvider {
  _FixedProvider(this.deltas);

  final List<Delta> deltas;
  AiRequest? last;

  @override
  String get id => 'fixed';

  @override
  String get label => '固定';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(tools: true);

  @override
  Future<void> verify() async {}

  @override
  Stream<Delta> stream(AiRequest request) async* {
    last = request;
    for (final delta in deltas) {
      yield delta;
    }
  }
}

/// A provider whose endpoint or key is wrong.
class _FailingProvider implements AiProvider {
  @override
  String get id => 'failing';

  @override
  String get label => '失敗';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();

  @override
  Future<void> verify() async => throw const AiProviderException('APIキーが受け付けられませんでした（HTTP 401）');

  @override
  Stream<Delta> stream(AiRequest request) async* {
    throw const AiProviderException('APIキーが受け付けられませんでした（HTTP 401）');
  }
}

void main() {
  test('本文を順に流し、最後に理由を返す', () async {
    final engine = CloudEngine(_FixedProvider(const [
      TextDelta('こん'),
      TextDelta('にちは'),
      StopDelta(FinishReason.eog),
    ]));
    final events = await engine.generate(_request()).toList();
    expect(events.whereType<Piece>().map((p) => p.text).join(), 'こんにちは');
    expect((events.last as Finished).reason, FinishReason.eog);
  });

  test('プロンプトはシステムとユーザーのメッセージになり、設定がそのまま渡る', () async {
    final provider = _FixedProvider(const [TextDelta('ok'), StopDelta(FinishReason.eog)]);
    await CloudEngine(provider).generate(_request(maxTokens: 128)).toList();

    final sent = provider.last!;
    expect(sent.messages.first.role, AiRole.system);
    expect(sent.messages.last.role, AiRole.user);
    expect(sent.messages.last.text, 'こんにちは');
    expect(sent.maxTokens, 128);
    expect(sent.temperature, 0.3);
    expect(sent.topP, 0.9);
  });

  test('思考はセグメンタが思考として読む', () async {
    final engine = CloudEngine(_FixedProvider(const [
      ReasoningDelta('考え中'),
      TextDelta('答え'),
      StopDelta(FinishReason.eog),
    ]));
    final thinking = StringBuffer();
    final answer = StringBuffer();
    final segmenter = StreamSegmenter();
    for (final event in segmenter.feed(await _piecesOf(engine))) {
      switch (event) {
        case ThinkingText(:final text):
          thinking.write(text);
        case PlainText(:final text):
          answer.write(text);
        default:
          break;
      }
    }
    for (final event in segmenter.finish()) {
      if (event is ThinkingText) thinking.write(event.text);
      if (event is PlainText) answer.write(event.text);
    }
    expect(thinking.toString(), '考え中');
    expect(answer.toString(), '答え');
  });

  test('道具の呼び出しは、既存の解析でそのまま読める', () async {
    final engine = CloudEngine(_FixedProvider(const [
      ToolCallDelta(id: 'call_1', name: 'web_search', argumentsJson: '{"query": "天気"}'),
      StopDelta(FinishReason.eog),
    ]));
    final segmenter = StreamSegmenter();
    final bodies = <String>[];
    for (final event in segmenter.feed(await _piecesOf(engine))) {
      if (event is ToolCallEnd) bodies.add(event.json);
    }
    expect(bodies, hasLength(1));
    final body = jsonDecode(bodies.single) as Map<String, Object?>;
    expect(body['name'], 'web_search');
    expect(body['arguments'], {'query': '天気'});
  });

  test('理由を送らずに終わるプロバイダでも、終わりは eog になる', () async {
    final events = await CloudEngine(_FixedProvider(const [TextDelta('途中')])).generate(_request()).toList();
    expect((events.last as Finished).reason, FinishReason.eog);
  });

  test('プロバイダの失敗は、その文言のままエンジンのエラーになる', () async {
    await expectLater(
      CloudEngine(_FailingProvider()).generate(_request()).toList(),
      throwsA(isA<EngineException>().having((e) => e.message, 'message', contains('APIキー'))),
    );
  });

  test('何も組み立てられないプロンプトは送らない', () async {
    final provider = _FixedProvider(const []);
    final request = GenerateRequest(
      prompt: 'ChatML ではない文',
      toolCallSchema: null,
      thinking: false,
      maxTokens: 16,
      sampling: _sampling,
    );
    await expectLater(
      CloudEngine(provider).generate(request).toList(),
      throwsA(isA<EngineException>()),
    );
    expect(provider.last, isNull);
  });
}

/// The reply text of [engine] as one piece, so the segmenter sees a normal stream.
Future<String> _piecesOf(CloudEngine engine) async {
  final text = StringBuffer();
  await for (final event in engine.generate(_request())) {
    if (event is Piece) text.write(event.text);
  }
  return text.toString();
}
