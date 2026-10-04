import 'dart:collection';

import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/tool_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replays one scripted reply per generate() call, split into small pieces like real tokens.
class ScriptedEngine implements InferenceEngine {
  ScriptedEngine(Iterable<(String, FinishReason)> replies) : _queue = Queue.of(replies);

  final Queue<(String, FinishReason)> _queue;
  final requests = <GenerateRequest>[];
  String? failWith;

  @override
  bool get isLoaded => true;
  @override
  Future<void> load(LoadParams params) async {}
  @override
  void cancel() {}
  @override
  Future<void> unload() async {}

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    requests.add(request);
    if (failWith != null) throw EngineException(failWith!);
    final (text, reason) = _queue.removeFirst();
    for (var i = 0; i < text.length; i += 3) {
      yield Piece(text.substring(i, i + 3 > text.length ? text.length : i + 3));
    }
    yield Finished(reason);
  }
}

class _Runtime implements ToolRuntime {
  _Runtime(this._outcome);
  final ToolOutcome Function(ToolCall) _outcome;

  @override
  Future<ToolOutcome> run(ToolCall call) async => _outcome(call);
}

void main() {
  const askJson =
      '{"name":"ask_user","arguments":{"title":"どの言語？","options":["Kotlin","Java"],"allow_free_input":true}}';

  test('separates thinking from the answer', () async {
    final chat = ChatController(ScriptedEngine([('<think>考え中</think>こんにちは', FinishReason.eog)]));
    await chat.send('hi');
    final reply = chat.state.messages.last;
    expect(reply.thinking, '考え中');
    expect(reply.text, 'こんにちは');
    expect(chat.state.task, TaskState.completed);
  });

  test('a tool call becomes a question tile and the answer resumes generation', () async {
    final engine = ScriptedEngine([
      ('<think>聞く</think>確認します。<tool_call>\n$askJson\n</tool_call>', FinishReason.eog),
      ('<think></think>Kotlinで作ります。', FinishReason.eog),
    ]);
    final chat = ChatController(engine);
    await chat.send('アプリを作って');

    expect(chat.state.task, TaskState.userWait);
    expect(
      chat.state.pendingQuestion,
      const QuestionTile(title: 'どの言語？', options: ['Kotlin', 'Java'], allowFreeInput: true, multiSelect: false),
    );
    expect(engine.requests.single.toolCallSchema, isNotNull);

    await chat.answer(['Kotlin'], null);
    expect(chat.state.pendingQuestion, isNull);
    expect(chat.state.messages.last.text, 'Kotlinで作ります。');
    expect(engine.requests.last.prompt, contains('<tool_response>\nKotlin\n</tool_response>'));
    expect(engine.requests.last.prompt, contains('<tool_call>\n$askJson\n</tool_call>'));
  });

  test('a tool call cut off by the token limit is regenerated', () async {
    final engine = ScriptedEngine([
      ('<tool_call>\n{"name":"ask_', FinishReason.length),
      ('<tool_call>\n$askJson\n</tool_call>', FinishReason.eog),
    ]);
    final chat = ChatController(engine);
    await chat.send('質問して');
    expect(engine.requests, hasLength(2));
    expect(chat.state.task, TaskState.userWait);
  });

  test('a stopped reply can be continued from where it ended', () async {
    final engine = ScriptedEngine([
      ('<think>x</think>前半', FinishReason.cancelled),
      ('と後半', FinishReason.eog),
    ]);
    final chat = ChatController(engine);
    await chat.send('長い説明をして');
    expect(chat.state.canContinue, isTrue);

    await chat.continueReply();
    expect(chat.state.messages.last.text, '前半と後半');
    expect(chat.state.canContinue, isFalse);
    expect(engine.requests.last.thinking, isFalse, reason: 'a continuation does not reason again');
    expect(engine.requests.last.prompt, endsWith('前半'));
  });

  test('regenerate replaces the last reply using the same prompt', () async {
    final engine = ScriptedEngine([('一回目', FinishReason.eog), ('二回目', FinishReason.eog)]);
    final chat = ChatController(engine);
    await chat.send('hi');
    await chat.regenerate();
    expect(chat.state.messages.map((m) => m.text), ['hi', '二回目']);
    expect(engine.requests[0].prompt, engine.requests[1].prompt);
  });

  test('an invalid question is reported, not shown', () async {
    const bad = '{"name":"ask_user","arguments":{"title":"q","options":["a","a"]}}';
    final chat = ChatController(ScriptedEngine([('<tool_call>\n$bad\n</tool_call>', FinishReason.eog)]));
    await chat.send('質問して');
    expect(chat.state.task, TaskState.error);
    expect(chat.state.error, 'options are not distinct');
    expect(chat.state.pendingQuestion, isNull);
  });

  test('a search tool call is run and the answer continues in the same message', () async {
    final engine = ScriptedEngine([
      (
        '<think>調べる</think><tool_call>\n{"name":"web_search","arguments":{"query":"kotlin 2.4"}}\n</tool_call>',
        FinishReason.eog,
      ),
      ('<think></think>Kotlin 2.4 is out.', FinishReason.eog),
    ]);
    final runtime = _Runtime((_) => const ToolOutcome(
          '1. Kotlin 2.4 released https://kotlinlang.org',
          ToolActivity('Search', 'found', links: [Link('K', 'https://kotlinlang.org')]),
        ));
    final saved = <bool>[];
    final chat = ChatController(engine, toolRuntime: runtime, store: (_, {required generating}) => saved.add(generating));
    await chat.send('最新のKotlinを調べて');

    final reply = chat.state.messages.last;
    expect(reply.text, 'Kotlin 2.4 is out.');
    expect(reply.agent, 'Research / Search');
    expect(reply.activities.single.links.map((l) => l.url), ['https://kotlinlang.org']);
    expect(engine.requests.last.prompt, contains('<tool_response>\n1. Kotlin 2.4 released'));
    expect(chat.state.task, TaskState.completed);
    expect(saved, [true, false], reason: 'saved as unfinished at start, finished at the end');
  });

  test('tool loops are cut off', () async {
    const call = '<tool_call>\n{"name":"get_time","arguments":{}}\n</tool_call>';
    final engine = ScriptedEngine([for (var i = 0; i < 3; i++) (call, FinishReason.eog)]);
    final runtime = _Runtime((_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00')));
    final chat = ChatController(engine, toolRuntime: runtime, settings: () => const GenerationSettings(maxToolRounds: 2));
    await chat.send('何時？');
    expect(chat.state.task, TaskState.error);
    expect(engine.requests, hasLength(3));
  });

  test('search tool is withheld when search is off and small models get a notice', () async {
    final engine = ScriptedEngine([('ok', FinishReason.eog)]);
    final chat = ChatController(
      engine,
      settings: () => const GenerationSettings(searchEnabled: false, modelParamsB: 1.7),
    );
    await chat.send('最新のニュースを調べて');
    expect(engine.requests.single.toolCallSchema!, isNot(contains('web_search')));
    expect(chat.state.notice, isNotNull);
  });

  test('a snapshot restores the conversation', () async {
    final chat = ChatController(ScriptedEngine([('こんにちは', FinishReason.eog)]));
    await chat.send('hi');
    final json = chat.snapshot().toJson();

    final other = ChatController(ScriptedEngine([('next', FinishReason.eog)]));
    other.restore(ConversationSnapshot.fromJson(json));
    expect(other.state.messages.map((m) => m.text), ['hi', 'こんにちは']);
    await other.send('続けて');
    expect(other.state.messages.last.text, 'next');
    expect(other.snapshot().nextId, 4);
  });

  test('engine errors surface in the state', () async {
    final engine = ScriptedEngine([])..failWith = 'model load failed';
    final chat = ChatController(engine);
    await chat.send('hi');
    expect(chat.state.task, TaskState.error);
    expect(chat.state.error, 'model load failed');
  });
}
