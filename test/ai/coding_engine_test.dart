import 'dart:async';
import 'dart:convert';

import 'package:arce_ai/ai/coding_engine.dart';
import 'package:arce_ai/ai/cloud_engine.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/routing_engine.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/coding_plan.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:flutter_test/flutter_test.dart';

/// A model that answers from a script and records what it was asked, and how many requests were
/// running at once.
class FakeRole implements RoleModel {
  FakeRole(this.label, this.answer, {this.maxParallel = 4, this.delay = Duration.zero});

  @override
  final String label;
  @override
  final int maxParallel;
  final Duration delay;

  /// Called with each request's messages; returns the answer.
  final FutureOr<String> Function(List<AiMessage> messages) answer;

  final calls = <List<AiMessage>>[];
  int running = 0;
  int peak = 0;
  bool cancelled = false;

  @override
  Future<String> ask(
    List<AiMessage> messages, {
    required int maxTokens,
    required bool Function() cancelled,
    double temperature = 0.3,
    int autoTokens = 4096,
  }) async {
    calls.add(messages);
    running++;
    if (running > peak) peak = running;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      return await answer(messages);
    } finally {
      running--;
    }
  }

  @override
  void cancel() => cancelled = true;
}

String plan(int tasks) => jsonEncode({
      'summary': '共有の決めごと',
      'tasks': [
        for (var i = 1; i <= tasks; i++) {'id': 't$i', 'title': 'タスク$i', 'instructions': '$i を作る'},
      ],
    });

GenerateRequest request({String agent = 'coding', bool continuation = false, String user = 'ツールを作って'}) => GenerateRequest(
      prompt: ChatMlPromptBuilder.build([UserTurn(user)], const [], null, false),
      toolCallSchema: null,
      thinking: false,
      maxTokens: 100,
      sampling: SamplingParams.qwen3NonThinking,
      agentId: agent,
      continuation: continuation,
    );

Future<(String, FinishReason?)> run(CodingEngine engine, GenerateRequest r) async {
  final text = StringBuffer();
  FinishReason? reason;
  await for (final e in engine.generate(r)) {
    if (e is Piece) text.write(e.text);
    if (e is Finished) reason = e.reason;
  }
  return (text.toString(), reason);
}

CodingEngine engineOf(FakeRole planner, FakeRole developer, {int reviewRounds = 1, int parallel = 3, bool enabled = true}) => CodingEngine(
      settings: () => CodingSettings(enabled: enabled, planner: 'p|m', developer: 'd|m', reviewRounds: reviewRounds, parallel: parallel, maxTasks: 8),
      roleFor: (ref) => ref.startsWith('p|') ? planner : developer,
    );

void main() {
  test('設計モデルが分け、開発モデルが書き、設計モデルが承認する', () async {
    final planner = FakeRole('設計役', (m) => m.first.text.contains('reviewing') ? '{"approved": true, "notes": "よし"}' : plan(2));
    final developer = FakeRole('開発役', (m) => '```python\n# ${m.last.text.contains('1 を作る') ? 'one' : 'two'}\n```');
    final (text, reason) = await run(engineOf(planner, developer), request());

    expect(reason, FinishReason.eog);
    expect(text, contains('**設計**（設計役）'));
    expect(text, contains('共有の決めごと'));
    expect(text, contains('1. タスク1'));
    expect(text, contains('開発: 開発役'));
    expect(text, contains('> レビュー: 承認'));
    // the results come back in the order of the plan
    expect(text.indexOf('### 1. タスク1'), lessThan(text.indexOf('### 2. タスク2')));
    expect(text, contains('# one'));
    expect(text, contains('# two'));
    expect(text, contains('**レビューのメモ**: よし'));

    expect(planner.calls, hasLength(2), reason: 'a plan, then a review: the expensive model writes no code');
    expect(developer.calls, hasLength(2));
  });

  test('開発モデルには、会話の全体ではなく依頼と計画とそのタスクだけを送る', () async {
    final planner = FakeRole('P', (m) => m.first.text.contains('reviewing') ? '{"approved": true}' : plan(2));
    final developer = FakeRole('D', (_) => 'ok');
    await run(engineOf(planner, developer), request(user: '秘密の依頼文'));

    final first = developer.calls.first;
    expect(first.first.role, AiRole.system);
    expect(first.last.text, contains('秘密の依頼文'));
    expect(first.last.text, contains('共有の決めごと'));
    final both = developer.calls.map((c) => c.last.text).join();
    expect(both, contains('1 を作る'));
    expect(first.last.text.contains('2 を作る') && first.last.text.contains('1 を作る'), isFalse);
  });

  test('開発のリクエストは同時に走る。上限は設定と、モデルの同時数の小さいほう', () async {
    final planner = FakeRole('P', (m) => m.first.text.contains('reviewing') ? '{"approved": true}' : plan(6));
    final developer = FakeRole('D', (_) => 'ok', delay: const Duration(milliseconds: 20));
    await run(engineOf(planner, developer, parallel: 3), request());
    expect(developer.peak, 3, reason: '6 tasks, 3 at a time');
    expect(developer.calls, hasLength(6));

    final local = FakeRole('端末', (_) => 'ok', maxParallel: 1, delay: const Duration(milliseconds: 10));
    await run(engineOf(FakeRole('P', (m) => m.first.text.contains('reviewing') ? '{"approved": true}' : plan(4)), local, parallel: 8), request());
    expect(local.peak, 1, reason: 'the device model never runs two at once');
    expect(local.calls, hasLength(4));
  });

  test('レビューで差し戻されたタスクだけ、前の出力と指摘つきで書き直す', () async {
    var reviews = 0;
    final planner = FakeRole('P', (m) {
      if (!m.first.text.contains('reviewing')) return plan(2);
      reviews++;
      return '{"approved": false, "notes": "t2 の型", "fixes": [{"task": "t2", "instructions": "int にして"}]}';
    });
    final developer = FakeRole('D', (m) => m.length > 2 ? 'FIXED' : 'FIRST');
    final (text, _) = await run(engineOf(planner, developer, reviewRounds: 1), request());

    expect(reviews, 1, reason: 'one round of review, as set');
    expect(developer.calls, hasLength(3), reason: 'two tasks, then only t2 again');
    final redo = developer.calls.last;
    expect(redo[redo.length - 2].role, AiRole.assistant);
    expect(redo[redo.length - 2].text, 'FIRST', reason: 'the developer sees what it wrote before');
    expect(redo.last.text, contains('int にして'));
    expect(text, contains('> レビュー1: 1件の修正を指示（t2）'));
    expect(text.indexOf('FIRST'), isNonNegative);
    expect(text, contains('FIXED'));
    expect(RegExp('FIRST').allMatches(text).length, 1, reason: 'only t1 keeps its first answer');
  });

  test('レビューの回数が0なら、レビューしない', () async {
    final planner = FakeRole('P', (_) => plan(1));
    final developer = FakeRole('D', (_) => 'ok');
    await run(engineOf(planner, developer, reviewRounds: 0), request());
    expect(planner.calls, hasLength(1));
  });

  test('レビューは設定の回数まで。承認されなくても、そこで終わる', () async {
    final planner = FakeRole('P', (m) => m.first.text.contains('reviewing')
        ? '{"approved": false, "fixes": [{"task": "t1", "instructions": "もう一度"}]}'
        : plan(1));
    final developer = FakeRole('D', (_) => 'ok');
    final (_, reason) = await run(engineOf(planner, developer, reviewRounds: 2), request());
    expect(reason, FinishReason.eog);
    expect(planner.calls, hasLength(3), reason: 'plan + 2 reviews');
    expect(developer.calls, hasLength(3), reason: 'the first go + 2 rewrites');
  });

  test('計画が JSON でなければ、設計モデルの答えをそのまま返す（質問など）', () async {
    final planner = FakeRole('P', (_) => 'どの言語で作りますか？');
    final developer = FakeRole('D', (_) => 'unused');
    final (text, reason) = await run(engineOf(planner, developer), request());
    expect(text, 'どの言語で作りますか？');
    expect(reason, FinishReason.eog);
    expect(developer.calls, isEmpty, reason: 'nothing to develop, nothing to pay for');
  });

  test('1つのタスクが失敗しても、他のタスクの結果は返す', () async {
    final planner = FakeRole('P', (m) => m.first.text.contains('reviewing') ? '{"approved": true}' : plan(2));
    final developer = FakeRole('D', (m) {
      if (m.last.text.contains('2 を作る')) throw EngineException('429 Too Many Requests');
      return 'OK-1';
    });
    final (text, reason) = await run(engineOf(planner, developer), request());
    expect(reason, FinishReason.eog);
    expect(text, contains('OK-1'));
    expect(text, contains('このタスクは失敗しました: 429 Too Many Requests'));
  });

  test('設計モデルが失敗したら、エラーとして伝える', () async {
    final planner = FakeRole('P', (_) => throw EngineException('401 Unauthorized'));
    final engine = engineOf(planner, FakeRole('D', (_) => 'x'));
    await expectLater(run(engine, request()), throwsA(isA<EngineException>().having((e) => e.message, 'message', contains('401'))));
  });

  test('止めると、以降のリクエストを送らず、cancelled で終わる', () async {
    final planner = FakeRole('P', (_) => plan(3));
    final developer = FakeRole('D', (_) => 'ok', delay: const Duration(milliseconds: 30), maxParallel: 1);
    final engine = engineOf(planner, developer, reviewRounds: 0, parallel: 1);
    final events = <GenerationEvent>[];
    final done = Completer<void>();
    engine.generate(request()).listen(events.add, onDone: done.complete);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    engine.cancel();
    await done.future;
    expect(events.last, isA<Finished>().having((f) => f.reason, 'reason', FinishReason.cancelled));
    expect(developer.calls.length, lessThan(3), reason: 'the queued tasks never started');
    expect(developer.cancelled, isTrue);
  });

  group('いつ使うか', () {
    final planner = FakeRole('P', (_) => '');
    final developer = FakeRole('D', (_) => '');

    test('coding エージェントの新しい返信のときだけ', () {
      final engine = engineOf(planner, developer);
      expect(engine.handles(request()), isTrue);
      expect(engine.handles(request(agent: 'general')), isFalse);
      expect(engine.handles(request(continuation: true)), isFalse, reason: 'a cut-off reply stays with its engine');
    });

    test('オフのとき・役が足りないときは使わない', () {
      expect(engineOf(planner, developer, enabled: false).handles(request()), isFalse);
      final missing = CodingEngine(
        settings: () => const CodingSettings(enabled: true, planner: 'p|m', developer: 'd|m'),
        roleFor: (ref) => ref.startsWith('p|') ? planner : null,
      );
      expect(missing.handles(request()), isFalse, reason: 'the developer model is not usable');
    });
  });

  test('端末のモデルの役は ChatML で、思考を閉じたまま答えさせる', () {
    final prompt = LocalRole.chatMl(const [AiMessage(AiRole.system, text: 'S'), AiMessage(AiRole.user, text: 'U')]);
    expect(prompt, startsWith('<|im_start|>system\nS<|im_end|>\n<|im_start|>user\nU<|im_end|>\n'));
    expect(prompt, endsWith('<|im_start|>assistant\n<think>\n\n</think>\n\n'));
  });

  group('チャットとの組み込み', () {
    test('RoutingEngine は coding エージェントのときだけ、2つのモデルに分ける', () async {
      final planner = FakeRole('P', (_) => 'どの言語？');
      final developer = FakeRole('D', (_) => 'unused');
      final local = _Local();
      final routing = RoutingEngine(local: local, cloud: CloudEngine(_NoProvider()))..coding = engineOf(planner, developer);

      final (split, _) = await run2(routing, request());
      expect(split, 'どの言語？');
      expect(local.calls, 0, reason: 'the engine in use is not asked');

      await run2(routing, request(agent: 'general'));
      expect(local.calls, 1, reason: 'any other agent goes the usual way');
      expect(planner.calls, hasLength(1));
    });

    test('ChatController は、どのエージェントの返信かと、続きかどうかをエンジンに伝える', () async {
      final engine = _Recording();
      final chat = ChatController(engine);
      await chat.send('Kotlin のコードを実装して');
      expect(engine.requests.single.agentId, 'coding', reason: 'the request is about code');
      expect(engine.requests.single.continuation, isFalse);
    });
  });
}

Future<(String, FinishReason?)> run2(InferenceEngine engine, GenerateRequest r) async {
  final text = StringBuffer();
  FinishReason? reason;
  await for (final e in engine.generate(r)) {
    if (e is Piece) text.write(e.text);
    if (e is Finished) reason = e.reason;
  }
  return (text.toString(), reason);
}

class _Local implements InferenceEngine {
  int calls = 0;
  @override
  bool get isLoaded => true;
  @override
  Future<void> load(LoadParams params) async {}
  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    calls++;
    yield const Piece('端末');
    yield const Finished(FinishReason.eog);
  }

  @override
  void cancel() {}
  @override
  Future<void> unload() async {}
}

class _Recording extends _Local {
  final requests = <GenerateRequest>[];
  @override
  Stream<GenerationEvent> generate(GenerateRequest request) {
    requests.add(request);
    return super.generate(request);
  }
}

class _NoProvider implements AiProvider {
  @override
  String get id => 'none';
  @override
  String get label => 'none';
  @override
  String get modelId => '';
  @override
  ModelConfig? get modelConfig => null;
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();
  @override
  Stream<Delta> stream(AiRequest request) => const Stream.empty();
  @override
  Future<void> verify() async {}
}
