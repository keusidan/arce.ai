import 'dart:convert';

import '../core/attachments.dart';
import '../core/engine.dart';
import '../core/stream_segmenter.dart' hide ToolCallDelta;
import 'provider.dart';

/// Turns the ChatML prompt the chat builds into the messages a cloud provider expects, and turns
/// the provider's deltas back into the events the chat already understands.
///
/// One prompt is built for whichever engine answers, so the conversation must not change shape
/// between local and cloud: each block becomes a system / user / assistant message, and the
/// `<tool_call>` / `<tool_response>` conventions stay in the text exactly as the local model
/// receives them. Providers therefore see the same instructions the device would.
abstract final class ChatMlBridge {
  static const _start = '<|im_start|>';
  static const _end = '<|im_end|>';

  /// Sent after a reply that was already started ("続行"): a provider cannot be given a prefill,
  /// so the text written so far goes as the last assistant message and the model is asked to
  /// carry on from it.
  static const continuationNote =
      'Continue the answer above from exactly where it stops. '
      'Do not repeat what is already written and do not start over.';

  /// The messages of [prompt]. The reply block at the end is usually empty (it only means
  /// "answer now") and is dropped; a non-empty one is a continuation.
  ///
  /// A picture the user attached is marked in the text (see [ImageMarker]). When [vision] is true
  /// and the bytes are in [images] it goes to the provider as a picture; otherwise the marker
  /// becomes the file's name, so the model still knows something was attached.
  static List<AiMessage> messages(
    String prompt, {
    Map<String, ImageData> images = const {},
    bool vision = false,
  }) {
    final out = <AiMessage>[];
    var cursor = 0;

    while (cursor < prompt.length) {
      final open = prompt.indexOf(_start, cursor);
      if (open < 0) break;
      final bodyStart = open + _start.length;
      final close = prompt.indexOf(_end, bodyStart);
      final body = close < 0 ? prompt.substring(bodyStart) : prompt.substring(bodyStart, close);
      cursor = close < 0 ? prompt.length : close + _end.length;

      final newline = body.indexOf('\n');
      if (newline < 0) continue;
      final role = body.substring(0, newline).trim().toLowerCase();
      final text = body.substring(newline + 1);

      // The reply that is about to be written has no closing tag yet.
      if (close < 0) {
        final partial = _cleanAnswer(text);
        if (role == 'assistant' && partial.isNotEmpty) {
          out
            ..add(AiMessage(AiRole.assistant, text: partial))
            ..add(const AiMessage(AiRole.user, text: continuationNote));
        }
        break;
      }

      switch (role) {
        case 'system':
          out.add(AiMessage(AiRole.system, text: text.trim()));
        case 'user':
          out.add(_user(text.trim(), images, vision));
        case 'assistant':
          out.add(AiMessage(AiRole.assistant, text: _cleanAnswer(text)));
      }
    }
    return out;
  }

  static AiMessage _user(String text, Map<String, ImageData> images, bool vision) {
    final attached = <ImageData>[];
    final shown = text.replaceAllMapped(ImageMarker.pattern, (m) {
      final image = vision ? images[m.group(1)] : null;
      if (image != null) {
        attached.add(image);
        return '';
      }
      return '[画像: ${m.group(2)}]';
    });
    return AiMessage(AiRole.user, text: shown.trim(), images: attached);
  }

  /// Drops the empty thinking block the prompt starts a reply with, and the blank lines around it.
  static String _cleanAnswer(String text) {
    final trimmed = text.trim();
    final open = StreamSegmenter.thinkOpen.trim();
    final close = StreamSegmenter.thinkClose.trim();
    if (!trimmed.startsWith(open)) return trimmed;
    final end = trimmed.indexOf(close);
    if (end < 0 || trimmed.substring(0, end).trim() != open) return trimmed;
    return trimmed.substring(end + close.length).trim();
  }
}

/// Turns provider deltas into the events the chat pipeline already handles.
///
/// Thinking is wrapped in the tags [StreamSegmenter] looks for, and a native tool call is written
/// back as a `<tool_call>` body, so the segmenter and the tool-call parser read a cloud reply
/// exactly like a local one.
class CloudEventAdapter {
  bool _thinking = false;
  bool _finished = false;

  /// True once the provider said why it stopped.
  bool get isFinished => _finished;

  /// True between a reasoning delta and the reply text that follows it.
  bool get isThinking => _thinking;

  List<GenerationEvent> convert(Delta delta) {
    switch (delta) {
      case TextDelta(:final text):
        return [
          if (_thinking) ..._closeThinking(),
          if (text.isNotEmpty) Piece(text),
        ];
      case ReasoningDelta(:final text):
        return [
          if (!_thinking) ..._openThinking(),
          if (text.isNotEmpty) Piece(text),
        ];
      case ToolCallDelta(:final name, :final argumentsJson):
        final arguments = argumentsJson.trim().isEmpty ? '{}' : argumentsJson;
        return [
          ..._closeThinking(),
          Piece(
            '${StreamSegmenter.toolOpen}'
            '{"name": ${jsonEncode(name)}, "arguments": $arguments}'
            '${StreamSegmenter.toolClose}',
          ),
        ];
      case UsageDelta():
        // Token counts belong next to the message, not in the text.
        return const [];
      case StopDelta(:final reason):
        _finished = true;
        return [..._closeThinking(), Finished(reason)];
    }
  }

  List<GenerationEvent> _openThinking() {
    _thinking = true;
    return const [Piece(StreamSegmenter.thinkOpen)];
  }

  List<GenerationEvent> _closeThinking() {
    if (!_thinking) return const [];
    _thinking = false;
    return const [Piece(StreamSegmenter.thinkClose)];
  }
}
