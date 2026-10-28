import 'dart:convert';

import 'protocol.dart';

sealed class ChatMessage {
  const ChatMessage();

  Map<String, Object?> toJson();

  factory ChatMessage.fromJson(Map<String, Object?> json) {
    switch (json['type']) {
      case 'user':
        return UserTurn(json['text'] as String);
      case 'assistant':
        return AssistantTurn(json['text'] as String, json['toolCallJson'] as String?, json['reasoning'] as String?);
      case 'tool':
        return ToolResponseTurn(json['text'] as String);
    }
    throw FormatException('unknown message type ${json['type']}');
  }
}

class UserTurn extends ChatMessage {
  const UserTurn(this.text);
  final String text;

  @override
  Map<String, Object?> toJson() => {'type': 'user', 'text': text};
}

/// Past assistant turns keep only the answer; Qwen3 drops old reasoning from the context.
class AssistantTurn extends ChatMessage {
  const AssistantTurn(this.text, [this.toolCallJson, this.reasoning]);
  final String text;
  final String? toolCallJson;

  /// What the model thought before it answered. It is never part of the prompt text (the device
  /// model does not see it); a provider that wants it back (DeepSeek and GLM, when tools are in
  /// use) receives it beside the prompt (`GenerateRequest.reasoning`).
  final String? reasoning;

  @override
  Map<String, Object?> toJson() => {
        'type': 'assistant',
        'text': text,
        'toolCallJson': toolCallJson,
        if (reasoning != null && reasoning!.isNotEmpty) 'reasoning': reasoning,
      };
}

/// The user's answer to a tool call such as ask_user.
class ToolResponseTurn extends ChatMessage {
  const ToolResponseTurn(this.text);
  final String text;

  @override
  Map<String, Object?> toJson() => {'type': 'tool', 'text': text};
}

/// Builds a Qwen3 ChatML prompt.
///
/// The fixed system prompt and the user's tone request are kept apart: the tone text is
/// sanitised and placed in its own delimited section, so it can change how answers sound but
/// cannot close the system block or forge tool-call tags.
abstract final class ChatMlPromptBuilder {
  static const toneMaxChars = 200;

  static const _imStart = '<|im_start|>';
  static const _imEnd = '<|im_end|>';

  static const baseSystemPrompt = '''
You are ARCE.AI, a local assistant for coding and general questions.
Rules:
- Write replies in Markdown: lists, **bold**, tables for comparisons, and headings only in longer answers.
- Put every program or file in a fenced code block with its language, e.g. ```html.
- Only write code when the user clearly asks for it ("make", "implement", "write code", 作って, 実装して). Otherwise answer in prose.
- If you need a decision from the user before continuing, call the ask_user tool instead of guessing.
- Never wait with a fixed-duration sleep (e.g. sleep 5, sleep 30, or blind timers). Always wait for the actual response, process exit, or readiness condition to complete, while keeping an explicit timeout.
- Every local command in the app's Linux environment (run_command) runs automatically without user approval; decide and run it directly. Set auto_execute: false only when you want the user to see the command before it runs.
- Do not repeat the wording of your previous reply; rephrase unless exact repetition is required.''';