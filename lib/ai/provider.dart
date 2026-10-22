import '../core/attachments.dart';
import '../core/generation.dart';
import 'provider_config.dart';

/// One piece of what a model sends back while it writes.
///
/// Providers differ in how they report thinking, tool calls and token usage; every adapter turns
/// them into these five kinds, so the chat pipeline never has to know which provider it talks to.
sealed class Delta {
  const Delta();
}

class TextDelta extends Delta {
  const TextDelta(this.text);
  final String text;
}

/// The model's thinking, shown folded in the chat. Providers that do not send it simply omit it.
class ReasoningDelta extends Delta {
  const ReasoningDelta(this.text);
  final String text;
}

/// A tool call the model wants to make. Adapters send it only once it is complete, with the
/// arguments as JSON text, so the existing tool-call parser reads it exactly like a local call.
class ToolCallDelta extends Delta {
  const ToolCallDelta({
    required this.name,
    required this.argumentsJson,
    this.id = '',
  });
  final String id;
  final String name;
  final String argumentsJson;
}

/// Token usage for one request, sent at the end by providers that report it.
class UsageDelta extends Delta {
  const UsageDelta({this.promptTokens, this.completionTokens});
  final int? promptTokens;
  final int? completionTokens;
}

/// Why the model stopped. Always the last delta of a reply.
class StopDelta extends Delta {
  const StopDelta(this.reason);
  final FinishReason reason;
}

enum AiRole { system, user, assistant, tool }

/// One message of the conversation as the provider expects it.
class AiMessage {
  const AiMessage(
    this.role, {
    this.text = '',
    this.toolCalls = const [],
    this.toolCallId = '',
    this.images = const [],
  });

  final AiRole role;
  final String text;

  /// Pictures sent with a user message. Only set for a provider that can see them.
  final List<ImageData> images;

  /// Calls the assistant made in this turn, kept so the provider sees its own request again.
  final List<ToolCallDelta> toolCalls;

  /// Which call a `tool` message answers.
  final String toolCallId;
}

/// A tool the model may call, in provider-neutral form.
class AiToolSpec {
  const AiToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;

  /// JSON Schema of the arguments, as the provider's function calling expects it.
  final Map<String, Object?> parameters;
}

class AiRequest {
  const AiRequest({
    required this.messages,
    this.model = '',
    this.tools = const [],
    this.maxTokens = 2048,
    this.temperature = 0.7,
    this.topP = 0.95,
  });

  final List<AiMessage> messages;

  /// The model to ask for; empty keeps the one the provider was built with.
  final String model;
  final List<AiToolSpec> tools;
  final int maxTokens;
  final double temperature;
  final double topP;
}

/// What a provider can do, so the screen can show only what works (a text-only model cannot take
/// an image, a provider that reports no usage cannot show a cost).
class ProviderCapabilities {
  const ProviderCapabilities({
    this.tools = false,
    this.reasoning = false,
    this.vision = false,
    this.usage = false,
  });

  final bool tools;
  final bool reasoning;
  final bool vision;

  /// Reports token counts, which the history stores next to the message.
  final bool usage;
}

/// A model endpoint: a cloud API or a local server that speaks the same protocol.
abstract interface class AiProvider {
  /// Stable id, also stored in the database (`conversations.provider_id`).
  String get id;

  /// What the settings screen shows.
  String get label;

  /// The model this provider was built for; empty when none was chosen.
  String get modelId;

  /// The per-model settings (sampling overrides, extra prompt), when known.
  ModelConfig? get modelConfig;

  ProviderCapabilities get capabilities;

  /// Streams one reply. Cancelling the subscription stops the request.
  Stream<Delta> stream(AiRequest request);

  /// Fails when the endpoint or the key is wrong; used by the connection check.
  Future<void> verify();
}

/// A failed request, with a message that can be shown as it is.
class AiProviderException implements Exception {
  const AiProviderException(this.message);
  final String message;

  @override
  String toString() => message;
}
