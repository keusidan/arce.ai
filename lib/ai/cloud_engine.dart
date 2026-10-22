import '../core/engine.dart';
import '../core/generation.dart';
import 'chatml_bridge.dart';
import 'model_hints.dart';
import 'provider.dart';
import 'provider_config.dart';
import 'thinking_config.dart';

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

  /// Whether tools go as function calling: the model's choice, or whatever the provider offers.
  static bool usesNativeTools(ModelConfig? model, bool providerOffersTools) => switch (model?.toolStyle ?? ToolStyle.auto) {
    ToolStyle.auto => providerOffersTools,
    ToolStyle.native => providerOffersTools,
    ToolStyle.text => false,
  };

  /// Whether the earlier reasoning goes back with the conversation. By default only for the models
  /// whose makers keep it (DeepSeek, GLM) and only while tools are function calls, which is
  /// where their guides keep it.
  static bool replaysReasoning(ModelConfig? model, String modelId, bool native) => switch (model?.thinking.replay ?? ReasoningReplay.auto) {
    ReasoningReplay.always => true,
    ReasoningReplay.never => false,
    ReasoningReplay.auto => native && ModelHints.familyOf(modelId) != ModelFamily.other,
  };

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    _cancelled = false;
    final model = provider.modelConfig;
    final native = usesNativeTools(model, provider.capabilities.tools);
    final messages = ChatMlBridge.messages(
      request.prompt,
      images: request.images,
      vision: provider.capabilities.vision,
      native: native,
      reasoning: request.assistantReasoning,
      replayReasoning: replaysReasoning(model, provider.modelId, native),
    );
    if (messages.isEmpty) {
      throw EngineException('送信する内容を組み立てられませんでした');
    }

    final adapter = CloudEventAdapter();
    final extraPrompt = model?.prompt.trim() ?? '';
    final allMessages = [
      if (extraPrompt.isNotEmpty) AiMessage(AiRole.system, text: extraPrompt),
      ...messages,
    ];
    // The value that applies, strongest first: the model's own setting, what the user set for
    // online models, the maker's recommendation (DeepSeek V4, GLM-5), the app's default.
    final hint = ModelHints.of(provider.modelId);
    final aiRequest = AiRequest(
      messages: allMessages,
      model: provider.modelId,
      maxTokens: ModelHints.resolveMaxTokens(
        modelSetting: model?.intParam('maxTokens'),
        requestedIsUserSet: request.user.maxTokens != null,
        requested: request.maxTokens,
        hint: hint,
        maxOutput: model?.maxOutputTokens,
        context: model?.contextTokens,
        promptTokens: ModelHints.estimateTokens(
          [for (final m in allMessages) m.text].join('\n') + [for (final t in request.tools) '${t.name}${t.description}${t.parameters}'].join(),
        ),
      ),
      extraBody: ThinkingRequest.fields(
        model?.thinking ?? ThinkingConfig.none,
        appThinking: request.thinking,
        speedAccuracy: request.user.speedAccuracy,
      ),
      temperature: model?.param('temperature') ?? request.user.temperature ?? hint?.temperature ?? request.sampling.temperature,
      topP: model?.param('topP') ?? request.user.topP ?? hint?.topP ?? request.sampling.topP,
      // With function calling the definitions travel here, and the conversation has the matching
      // shape (see [ChatMlBridge]); the text form keeps them in the system prompt instead, so
      // the model is never told about the same tools twice.
      tools: [
        if (native)
          for (final tool in request.tools)
            AiToolSpec(
              name: tool.name,
              description: tool.description,
              parameters: tool.parameters,
            ),
      ],
    );

    try {
      // takeWhile stops reading as soon as cancel() is called; the request is dropped.
      await for (final delta
          in provider.stream(aiRequest).takeWhile((_) => !_cancelled)) {
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
      for (final event in adapter.convert(
        const StopDelta(FinishReason.cancelled),
      )) {
        yield event;
      }
    } else if (!adapter.isFinished) {
      for (final event in adapter.convert(const StopDelta(FinishReason.eog))) {
        yield event;
      }
    }
  }
}
