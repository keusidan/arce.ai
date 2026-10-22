import 'attachments.dart';
import 'generation.dart';
import 'protocol.dart';

enum KvCacheType {
  f16(2.0),
  q8_0(1.0625);

  const KvCacheType(this.bytesPerElement);
  final double bytesPerElement;
}

class LoadParams {
  const LoadParams({
    required this.path,
    this.contextLength = 4096,
    this.threads = 4,
    // 0 = llama.cpp default.
    this.batchSize = 0,
    this.gpuLayers = 0,
    this.kvCache = KvCacheType.f16,
  });

  final String path;
  final int contextLength;
  final int threads;
  final int batchSize;
  final int gpuLayers;
  final KvCacheType kvCache;
}

class SamplingParams {
  const SamplingParams({
    required this.temperature,
    required this.topP,
    required this.topK,
    required this.minP,
    // 0 disables DRY; it discourages repeating earlier phrases (spec §55).
    this.dryMultiplier = 0.8,
  });

  // Qwen3 model card recommendations for each mode
  static const qwen3Thinking = SamplingParams(temperature: 0.6, topP: 0.95, topK: 20, minP: 0);
  static const qwen3NonThinking = SamplingParams(temperature: 0.7, topP: 0.8, topK: 20, minP: 0);

  final double temperature;
  final double topP;
  final int topK;
  final double minP;
  final double dryMultiplier;
}

class GenerateRequest {
  const GenerateRequest({
    required this.prompt,
    required this.toolCallSchema,
    required this.thinking,
    required this.maxTokens,
    required this.sampling,
    this.strictJsonSchema,
    this.tools = const [],
    this.images = const {},
  });

  final String prompt;

  /// The pictures the prompt marks (see `ImageMarker`), by id. Only an engine whose model can see
  /// reads them; the device engine ignores them.
  final Map<String, ImageData> images;

  /// JSON Schema of an allowed tool call; null means the agent has no tools and no grammar is applied.
  final String? toolCallSchema;
  final bool thinking;
  final int maxTokens;
  final SamplingParams sampling;

  /// JSON Schema the whole output must match (no lazy trigger); used for short classifications.
  final String? strictJsonSchema;

  /// The same tools [toolCallSchema] describes, in a form a cloud provider can take as function
  /// calling. The device engine ignores it: there the schema alone constrains the output.
  final List<ToolDefinition> tools;
}

sealed class GenerationEvent {
  const GenerationEvent();
}

class Piece extends GenerationEvent {
  const Piece(this.text);
  final String text;
}

class Finished extends GenerationEvent {
  const Finished(this.reason);
  final FinishReason reason;
}

class EngineException implements Exception {
  EngineException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Common surface of all inference backends, so chat, agents and Generation Tasks never
/// depend on a specific engine.
abstract interface class InferenceEngine {
  bool get isLoaded;
  Future<void> load(LoadParams params);
  Stream<GenerationEvent> generate(GenerateRequest request);

  /// Stops the running generation; the stream then ends with [FinishReason.cancelled].
  void cancel();
  Future<void> unload();
}
