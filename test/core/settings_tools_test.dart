import 'dart:collection';

import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/settings_spec.dart';
import 'package:arce_ai/core/tool_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replays one scripted reply per generate() call.
class _Engine implements InferenceEngine {
  _Engine(this._replies);

  final Queue<(String, FinishReason)> _replies;
  final requests = <GenerateRequest>[];

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
    final (text, reason) = _replies.removeFirst();
    yield Piece(text);
    yield Finished(reason);
  }
}

/// What the app would have stored; `get_settings` formats these values.
Map<String, Object?> sampleSettings() => {
      'thinking': true,
      'searchEnabled': false,
      'searxngUrl': '',
      'tone': '',
      'maxChars': 800,
      'speedAccuracy': 0.5,
      'hyperLoad': false,
      'theme': 'dark',
      'thinkingStyle': 'pulse',
      'agentOverride': '',
      'aiAgentSelection': true,
      'contextLength': 8192,
      'threads': 0,
      'batchSize': 0,
      'gpuOffload': 'auto',
      'maxTokens': 2048,
      'retryLimit': 2,
      'maxToolRounds': 4,
      'forceExecution': false,
      'autoUpdateCheck': true,
      'updateIntervalHours': 12,
    };

void main() {
  const updateJson = '{"name":"update_settings","arguments":{"changes":[{"key":"theme","value":"dark"}]}}';

  test('get_settings は許可されたエージェントだけが呼べる', () {
    final ok = ToolCallParser.parse('{"name":"get_settings","arguments":{}}', [Protocol.getSettings]);
    expect((ok as ParseOk).call, isA<GetSettings>());

    final refused = ToolCallParser.parse('{"name":"get_settings","arguments":{}}', [Protocol.askUser]);
    expect(refused, isA<ParseInvalid>());
  });

  test('describe は変更できる設定を現在値つきで並べる', () {
    final text = AgentSettings.describe(sampleSettings());
    for (final key in AgentSettings.keys) {
      expect(text, contains('- $key = '), reason: '設定 $key が抜けている');
    }
    expect(text, contains('theme = dark'));
    expect(text, contains('contextLength = 8192'));
    expect(text, contains('選択肢: system（端末に合わせる）'));
    expect(text, contains('範囲: 512〜131072'));
    expect(text, contains('lastModelPath'), reason: '触れない設定があることも伝える');
  });

  test('get_settings は設定ストアから現在値を返す', () async {
    final runtime = DefaultToolRuntime(settingsValues: sampleSettings);
    final out = await runtime.run(const GetSettings());
    expect(out.activity.failed, isFalse);
    expect(out.response, contains('theme = dark'));
    expect(out.response, contains('maxChars = 800'));

    final none = await DefaultToolRuntime().run(const GetSettings());
    expect(none.activity.failed, isTrue);
  });

  test('update_settings は承認カードになり、承認するまで書かない', () async {
    final engine = _Engine(Queue.of([
      ('<tool_call>\n$updateJson\n</tool_call>', FinishReason.eog),
      ('ダークにしました。', FinishReason.eog),
    ]));
    final applied = <List<SettingsChangeOk>>[];
    final chat = ChatController(
      engine,
      applySettings: (changes) async {
        applied.add(changes);
        return 'The user approved the change: theme=ダーク.';
      },
    );

    await chat.send('テーマをダークにして');
    expect(chat.state.pendingSettings?.single.key, 'theme');
    expect(chat.state.pendingQuestion?.options, [SettingsApproval.approve, SettingsApproval.reject]);
    expect(chat.state.pendingQuestion?.allowFreeInput, isFalse);
    expect(applied, isEmpty, reason: '承認前に書いてはいけない');

    await chat.answer([SettingsApproval.approve], null);
    expect(applied.single.single.value, 'dark');
    expect(engine.requests.last.prompt, contains('The user approved the change'));
    expect(chat.state.messages.last.text, 'ダークにしました。');
    expect(chat.state.pendingSettings, isNull);
  });

  test('拒否された変更は何も書かず、そう伝える', () async {
    final engine = _Engine(Queue.of([
      ('<tool_call>\n$updateJson\n</tool_call>', FinishReason.eog),
      ('やめておきます。', FinishReason.eog),
    ]));
    final applied = <List<SettingsChangeOk>>[];
    final chat = ChatController(
      engine,
      applySettings: (changes) async {
        applied.add(changes);
        return 'applied';
      },
    );

    await chat.send('テーマをダークにして');
    await chat.answer([SettingsApproval.reject], null);
    expect(applied, isEmpty);
    expect(engine.requests.last.prompt, contains('The user rejected the change'));
  });

  test('承認待ちは会話の保存から戻る', () async {
    final engine = _Engine(Queue.of([('<tool_call>\n$updateJson\n</tool_call>', FinishReason.eog)]));
    final chat = ChatController(engine, applySettings: (_) async => 'applied');
    await chat.send('テーマをダークにして');

    final other = ChatController(
      _Engine(Queue.of([('ok', FinishReason.eog)])),
      applySettings: (_) async => 'applied',
    );
    other.restore(ConversationSnapshot.fromJson(chat.snapshot().toJson()));
    expect(other.state.pendingSettings?.single.value, 'dark');
  });
}
