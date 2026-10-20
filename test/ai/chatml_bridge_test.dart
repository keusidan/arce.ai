import 'package:arce_ai/ai/chatml_bridge.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('プロンプトの分解', () {
    test('システム・履歴・空の返信ブロックを並べる（空の返信は送らない）', () {
      final messages = ChatMlBridge.messages(
        ChatMlPromptBuilder.build(const [UserTurn('こんにちは'), AssistantTurn('やあ')], const [], null, false),
      );
      expect([for (final m in messages) m.role], [AiRole.system, AiRole.user, AiRole.assistant]);
      expect(messages[1].text, 'こんにちは');
      expect(messages[2].text, 'やあ');
      expect(messages.first.text, contains('ARCE.AI'));
    });

    test('口調の指示はシステムメッセージの中に残る', () {
      final messages = ChatMlBridge.messages(
        ChatMlPromptBuilder.build(const [UserTurn('やあ')], const [], 'です・ます調で', false),
      );
      expect(messages.first.text, contains('<tone>です・ます調で</tone>'));
      expect([for (final m in messages) m.role], [AiRole.system, AiRole.user]);
    });

    test('道具の往復はローカルの書き方のまま残す', () {
      final messages = ChatMlBridge.messages(
        ChatMlPromptBuilder.build(
          const [
            UserTurn('いま何時'),
            AssistantTurn('', '{"name": "get_time", "arguments": {}}'),
            ToolResponseTurn('12:00'),
          ],
          const [],
          null,
          false,
        ),
      );
      expect(messages[2].text, contains('<tool_call>'));
      expect(messages[3].text, contains('<tool_response>'));
    });

    test('途中までの返信は、続きを書くよう指示を付けて送る', () {
      final messages = ChatMlBridge.messages(
        ChatMlPromptBuilder.build(const [UserTurn('続きを')], const [], null, false, assistantPrefill: '答えは'),
      );
      expect([for (final m in messages) m.role], [AiRole.system, AiRole.user, AiRole.assistant, AiRole.user]);
      expect(messages[2].text, '答えは');
      expect(messages[3].text, ChatMlBridge.continuationNote);
    });

    test('空の思考ブロックは送らない', () {
      final messages = ChatMlBridge.messages(
        ChatMlPromptBuilder.build(const [UserTurn('x')], const [], null, false, assistantPrefill: '後半'),
      );
      expect(messages[2].text, '後半');
    });

    test('ブロックが無ければ空になる', () {
      expect(ChatMlBridge.messages('ただの文'), isEmpty);
    });
  });

  group('Delta からチャットのイベントへ', () {
    test('本文はそのまま、終わりに理由を返す', () {
      final adapter = CloudEventAdapter();
      expect(adapter.convert(const TextDelta('あ')), [isA<Piece>()]);
      final end = adapter.convert(const StopDelta(FinishReason.length));
      expect(adapter.isFinished, isTrue);
      expect(end.whereType<Finished>().single.reason, FinishReason.length);
    });

    test('思考は思考ブロックで囲み、本文が来たら閉じる', () {
      final adapter = CloudEventAdapter();
      final thinking = adapter.convert(const ReasoningDelta('考える'));
      expect(thinking.whereType<Piece>().map((p) => p.text).join(), contains('考える'));
      expect(adapter.isThinking, isTrue);
      final text = adapter.convert(const TextDelta('答え'));
      expect(adapter.isThinking, isFalse);
      // the thinking block is closed first, then the reply text follows
      expect(text.first, isA<Piece>());
      expect(text.whereType<Piece>().map((p) => p.text).last, '答え');
    });

    test('道具の呼び出しは <tool_call> の本文に戻す', () {
      final adapter = CloudEventAdapter();
      final events = adapter.convert(
        const ToolCallDelta(name: 'web_search', argumentsJson: '{"query": "天気"}'),
      );
      final text = events.whereType<Piece>().map((p) => p.text).join();
      expect(text, contains('<tool_call>'));
      expect(text, contains('"name": "web_search"'));
      expect(text, contains('{"query": "天気"}'));
      expect(text, contains('</tool_call>'));
    });

    test('引数が空の道具呼び出しは {} にする', () {
      final events = CloudEventAdapter().convert(
        const ToolCallDelta(name: 'get_time', argumentsJson: ''),
      );
      expect(events.whereType<Piece>().single.text, contains('"arguments": {}'));
    });

    test('使用量はテキストにしない', () {
      expect(CloudEventAdapter().convert(const UsageDelta(promptTokens: 1, completionTokens: 2)), isEmpty);
    });

    test('最後に理由が来なければ、終わりは補える', () {
      final adapter = CloudEventAdapter();
      expect(adapter.isFinished, isFalse);
      final end = adapter.convert(const StopDelta(FinishReason.eog));
      expect(end.whereType<Finished>().single.reason, FinishReason.eog);
    });
  });
}
