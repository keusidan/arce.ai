import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:arce_ai/core/attachments.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/tool_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replays one scripted reply per generate() call, split into small pieces like real tokens.
class ScriptedEngine implements InferenceEngine {
  ScriptedEngine(Iterable<(String, FinishReason)> replies)
    : _queue = Queue.of(replies);

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

  test('an attached image is marked in the prompt and its bytes go with the request', () async {
    final engine = ScriptedEngine([('見えます', FinishReason.eog)]);
    final chat = ChatController(engine);
    final image = ImageData('image/png', Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]));

    await chat.send('これは何？', attachments: [Attachment('a.png', '', image: image)]);

    final request = engine.requests.single;
    expect(request.prompt, contains(ImageMarker.of('a.png', image)));
    expect(request.images[image.id], same(image));
    expect(chat.state.messages.first.text, 'これは何？', reason: 'the screen shows what the user typed, not the marker');
    expect(chat.state.messages.first.attachments, ['a.png']);

    // a new conversation drops the bytes; the saved marker stays in the history only
    chat.clear();
    await chat.send('次');
    expect(engine.requests.last.images, isEmpty);
  });

  test('separates thinking from the answer', () async {
    final chat = ChatController(
      ScriptedEngine([('<think>考え中</think>こんにちは', FinishReason.eog)]),
    );
    await chat.send('hi');
    final reply = chat.state.messages.last;
    expect(reply.thinking, '考え中');
    expect(reply.text, 'こんにちは');
    expect(chat.state.task, TaskState.completed);
  });

  test(
    'a tool call becomes a question tile and the answer resumes generation',
    () async {
      final engine = ScriptedEngine([
        (
          '<think>聞く</think>確認します。<tool_call>\n$askJson\n</tool_call>',
          FinishReason.eog,
        ),
        ('<think></think>Kotlinで作ります。', FinishReason.eog),
      ]);
      final chat = ChatController(engine);
      await chat.send('アプリを作って');

      expect(chat.state.task, TaskState.userWait);
      expect(
        chat.state.pendingQuestion,
        const QuestionTile(
          title: 'どの言語？',
          options: ['Kotlin', 'Java'],
          allowFreeInput: true,
          multiSelect: false,
        ),
      );
      expect(engine.requests.single.toolCallSchema, isNotNull);

      await chat.answer(['Kotlin'], null);
      expect(chat.state.pendingQuestion, isNull);
      expect(chat.state.messages.last.text, 'Kotlinで作ります。');
      expect(
        engine.requests.last.prompt,
        contains('<tool_response>\nKotlin\n</tool_response>'),
      );
      expect(
        engine.requests.last.prompt,
        contains('<tool_call>\n$askJson\n</tool_call>'),
      );
    },
  );

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
    expect(
      engine.requests.last.thinking,
      isFalse,
      reason: 'a continuation does not reason again',
    );
    expect(engine.requests.last.prompt, endsWith('前半'));
  });

  test('regenerate replaces the last reply using the same prompt', () async {
    final engine = ScriptedEngine([
      ('一回目', FinishReason.eog),
      ('二回目', FinishReason.eog),
    ]);
    final chat = ChatController(engine);
    await chat.send('hi');
    await chat.regenerate();
    expect(chat.state.messages.map((m) => m.text), ['hi', '二回目']);
    expect(engine.requests[0].prompt, engine.requests[1].prompt);
  });

  test('an invalid question is reported, not shown', () async {
    const bad =
        '{"name":"ask_user","arguments":{"title":"q","options":["a","a"]}}';
    final chat = ChatController(
      ScriptedEngine([('<tool_call>\n$bad\n</tool_call>', FinishReason.eog)]),
    );
    await chat.send('質問して');
    expect(chat.state.task, TaskState.error);
    expect(chat.state.error, 'options are not distinct');
    expect(chat.state.pendingQuestion, isNull);
  });

  test('two tool calls in one reply (parallel calls): the first one is run, not the last and not a failure', () async {
    final engine = ScriptedEngine([
      (
        '<tool_call>\n{"name":"web_search","arguments":{"query":"first"}}\n</tool_call>'
            '<tool_call>\n{"name":"web_search","arguments":{"query":"second"}}\n</tool_call>',
        FinishReason.eog,
      ),
      ('done', FinishReason.eog),
    ]);
    final queries = <String>[];
    final runtime = _Runtime((call) {
      queries.add((call as WebSearch).query);
      return const ToolOutcome('result', ToolActivity('Search', 'found'));
    });
    final chat = ChatController(engine, toolRuntime: runtime, store: (_, {required generating}) {});
    await chat.send('調べて');
    expect(queries, ['first']);
    expect(chat.state.messages.last.text, 'done');
  });

  test('a stop pressed before the request is sent (the tools are still being listed) is not forgotten', () async {
    final engine = ScriptedEngine([('この返信は届かない', FinishReason.eog)]);
    final listing = Completer<List<ToolDefinition>>();
    final chat = ChatController(engine, extraTools: () => listing.future, store: (_, {required generating}) {});
    final sent = chat.send('こんにちは');
    await Future<void>.delayed(Duration.zero);
    expect(chat.isRunning, isTrue);
    chat.stop(); // nothing is being generated yet
    listing.complete(const []);
    await sent;
    expect(engine.requests, isEmpty, reason: 'no request goes out after the stop');
    final reply = chat.state.messages.last;
    expect(reply.finish, FinishReason.cancelled);
    expect(chat.isRunning, isFalse);
    // and the next message is not stopped by the one before
    final next = ScriptedEngine([('ok', FinishReason.eog)]);
    final again = ChatController(next, store: (_, {required generating}) {});
    await again.send('x');
    expect(again.state.messages.last.text, 'ok');
  });

  test(
    'a search tool call is run and the answer continues in the same message',
    () async {
      final engine = ScriptedEngine([
        (
          '<think>調べる</think><tool_call>\n{"name":"web_search","arguments":{"query":"kotlin 2.4"}}\n</tool_call>',
          FinishReason.eog,
        ),
        ('<think></think>Kotlin 2.4 is out.', FinishReason.eog),
      ]);
      final runtime = _Runtime(
        (_) => const ToolOutcome(
          '1. Kotlin 2.4 released https://kotlinlang.org',
          ToolActivity(
            'Search',
            'found',
            links: [Link('K', 'https://kotlinlang.org')],
          ),
        ),
      );
      final saved = <bool>[];
      final chat = ChatController(
        engine,
        toolRuntime: runtime,
        store: (_, {required generating}) => saved.add(generating),
      );
      await chat.send('最新のKotlinを調べて');

      final reply = chat.state.messages.last;
      expect(reply.text, 'Kotlin 2.4 is out.');
      expect(reply.agent, 'Research / Search');
      expect(reply.activities.single.links.map((l) => l.url), [
        'https://kotlinlang.org',
      ]);
      expect(
        engine.requests.last.prompt,
        contains('<tool_response>\n1. Kotlin 2.4 released'),
      );
      expect(chat.state.task, TaskState.completed);
      expect(saved, [
        true,
        false,
      ], reason: 'saved as unfinished at start, finished at the end');
    },
  );

  test('tool loops are cut off', () async {
    const call =
        '<tool_call>\n{"name":"get_time","arguments":{}}\n</tool_call>';
    final engine = ScriptedEngine([
      for (var i = 0; i < 3; i++) (call, FinishReason.eog),
    ]);
    final runtime = _Runtime(
      (_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00')),
    );
    final chat = ChatController(
      engine,
      toolRuntime: runtime,
      settings: () => const GenerationSettings(maxToolRounds: 2),
    );
    await chat.send('何時？');
    expect(chat.state.task, TaskState.error);
    expect(engine.requests, hasLength(3));
  });

  test(
    'search tool is withheld when search is off and small models get a notice',
    () async {
      final engine = ScriptedEngine([('ok', FinishReason.eog)]);
      final chat = ChatController(
        engine,
        settings: () =>
            const GenerationSettings(searchEnabled: false, modelParamsB: 1.7),
      );
      await chat.send('最新のニュースを調べて');
      expect(
        engine.requests.single.toolCallSchema!,
        isNot(contains('web_search')),
      );
      expect(chat.state.notice, isNotNull);
    },
  );

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

  test('同じ道具を同じ引数で3回続けたら止まる', () async {
    const call = '{"name":"get_time","arguments":{}}';
    final engine = ScriptedEngine([
      ('<tool_call>\n$call\n</tool_call>', FinishReason.eog),
      ('<tool_call>\n$call\n</tool_call>', FinishReason.eog),
      ('<tool_call>\n$call\n</tool_call>', FinishReason.eog),
    ]);
    final chat = ChatController(
      engine,
      toolRuntime: _Runtime(
        (_) => const ToolOutcome(
          'Current time: 2026-10-21',
          ToolActivity('Time', '2026-10-21'),
        ),
      ),
    );
    await chat.send('いま何時？');
    expect(chat.state.task, TaskState.error);
    expect(chat.state.error, contains('同じ道具を同じ引数で繰り返し呼んでいます'));
    expect(engine.requests, hasLength(3));
  });

  String timeCall(String zone) => '<tool_call>\n{"name":"get_time","arguments":{"timezone":"$zone"}}\n</tool_call>';

  test('引数が違う呼び出しは、何回続いても止めない（以前は4回で「上限」になった）', () async {
    final zones = ['Asia/Tokyo', 'Europe/London', 'America/New_York', 'Asia/Seoul', 'Europe/Paris', 'Asia/Dubai', 'Australia/Sydney'];
    final engine = ScriptedEngine([
      for (final zone in zones) (timeCall(zone), FinishReason.eog),
      ('どこも調べました', FinishReason.eog),
    ]);
    final chat = ChatController(
      engine,
      toolRuntime: _Runtime((_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00'))),
    );
    await chat.send('世界の時刻を調べて');
    expect(chat.state.task, isNot(TaskState.error), reason: chat.state.error);
    expect(chat.state.messages.last.text, contains('どこも調べました'));
    expect(engine.requests, hasLength(zones.length + 1));
  });

  test('同じ呼び出しは、間に別の呼び出しをはさんでも、数えて止める', () async {
    final engine = ScriptedEngine([
      (timeCall('Asia/Tokyo'), FinishReason.eog),
      (timeCall('Asia/Seoul'), FinishReason.eog),
      (timeCall('Asia/Tokyo'), FinishReason.eog),
      (timeCall('Asia/Seoul'), FinishReason.eog),
      (timeCall('Asia/Tokyo'), FinishReason.eog),
      ('ここには来ない', FinishReason.eog),
    ]);
    final chat = ChatController(
      engine,
      toolRuntime: _Runtime((_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00'))),
    );
    await chat.send('時刻');
    expect(chat.state.task, TaskState.error);
    expect(chat.state.error, contains('同じ道具を同じ引数で繰り返し呼んでいます'));
    expect(engine.requests, hasLength(5));
  });

  test('上限に達したときは日本語で、どこで増やせるかを言う。0なら上限なし', () async {
    final engine = ScriptedEngine([
      (timeCall('Asia/Tokyo'), FinishReason.eog),
      (timeCall('Asia/Seoul'), FinishReason.eog),
      (timeCall('Asia/Dubai'), FinishReason.eog),
    ]);
    final capped = ChatController(
      engine,
      toolRuntime: _Runtime((_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00'))),
      settings: () => const GenerationSettings(maxToolRounds: 2),
    );
    await capped.send('時刻');
    expect(capped.state.error, contains('上限（2 回）'));
    expect(capped.state.error, contains('ツール呼び出しの上限'));

    final open = ChatController(
      ScriptedEngine([
        (timeCall('Asia/Tokyo'), FinishReason.eog),
        (timeCall('Asia/Seoul'), FinishReason.eog),
        (timeCall('Asia/Dubai'), FinishReason.eog),
        ('終わり', FinishReason.eog),
      ]),
      toolRuntime: _Runtime((_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00'))),
      settings: () => const GenerationSettings(maxToolRounds: 0),
    );
    await open.send('時刻');
    expect(open.state.task, isNot(TaskState.error), reason: open.state.error);
  });

  test('the thinking of each reply is kept in the history and goes back beside the next prompt, never inside it', () async {
    final engine = ScriptedEngine([
      (
        '<think>時刻を調べる</think><tool_call>\n{"name":"get_time","arguments":{}}\n</tool_call>',
        FinishReason.eog,
      ),
      ('<think>答える</think>正午です', FinishReason.eog),
    ]);
    final chat = ChatController(
      engine,
      toolRuntime: _Runtime((_) => const ToolOutcome('12:00', ToolActivity('Time', '12:00'))),
    );
    await chat.send('いま何時');

    expect(engine.requests, hasLength(2));
    expect(engine.requests.first.assistantReasoning, isEmpty);
    expect(engine.requests.last.assistantReasoning, hasLength(1));
    expect(engine.requests.last.assistantReasoning.single, contains('時刻を調べる'));
    expect(engine.requests.last.prompt, isNot(contains('時刻を調べる')), reason: 'the device model never sees old reasoning');

    final saved = chat.snapshot().history.whereType<AssistantTurn>().map((t) => t.reasoning).toList();
    expect(saved.first, contains('時刻を調べる'));
    expect(saved.last, contains('答える'));
  });
}
