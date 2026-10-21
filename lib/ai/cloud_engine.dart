import '../core/engine.dart';
import '../core/generation.dart';
import 'chatml_bridge.dart';
import 'provider.dart';

/// Answers through a cloud provider (or a local server that speaks the same protocol) while
/// looking like one more inference engine, so the chat, the agents and the retry policy stay as
/// they are.
///
/// The prompt the chat builds is ChatML; [ChatMlBridge] turns it into the provider's messages, and
/// the reply is turned back into pieces, tool calls included. Sampling settings, the token limit
/// and the tool schemas travel with the request as they do for the local engine.
class CloudEngine implements InferenceEngine {
  CloudEngine(this.provider);

  /// Replaced when the user switches provider; the next request uses the new one.
  AiProvider provider;

  bool _cancelled = false;

  /// Nothing is loaded on the device, so a cloud model is ready as soon as it is selected.
  @override
  bool get isLoaded => true;

  @override
  Future<void> load(LoadParams params) async {}

  @override
  Future<void> unload() async {}

  @override
  void cancel() => _cancelled = true;

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    _cancelled = false;
    final messages = ChatMlBridge.messages(request.prompt);
    if (messages.isEmpty) {
      throw EngineException('送信する内容を組み立てられませんでした');
    }

    final adapter = CloudEventAdapter();
    final aiRequest = AiRequest(
      messages: messages,
      // The prompt already teaches the `<tool_call>` form; sending the definitions as function
      // calling as well is what makes cloud models actually call one.
      tools: [
        if (provider.capabilities.tools)
          for (final tool in request.tools)
            AiToolSpec(name: tool.name, description: tool.description, parameters: tool.parameters),
      ],
      maxTokens: request.maxTokens,
      temperature: request.sampling.temperature,
      topP: request.sampling.topP,
    );

    try {
      // takeWhile stops reading as soon as cancel() is called; the request is dropped.
      await for (final delta in provider.stream(aiRequest).takeWhile((_) => !_cancelled)) {
        for (final event in adapter.convert(delta)) {
          yield event;
        }
      }
    } on AiProviderException catch (e) {
      throw EngineException(e.message);
    } catch (e) {
      throw EngineException('プロバイダとの通信に失敗しました（$e）');
    }

    // The chat expects a reason at the end, even when the provider sent none.
    if (_cancelled) {
      for (final event in adapter.convert(const StopDelta(FinishReason.cancelled))) {
        yield event;
      }
    } else if (!adapter.isFinished) {
      for (final event in adapter.convert(const StopDelta(FinishReason.eog))) {
        yield event;
      }
    }
  }
}
