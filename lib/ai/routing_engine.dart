import '../core/engine.dart';
import 'cloud_engine.dart';
import 'coding_engine.dart';
import 'provider.dart';

/// Sends each request to either the device model or a cloud provider, so the chat never has to
/// know which one answers.
///
/// Either one can be the one in use: the local model is not a fallback and the cloud is not a
/// special case. The choice is reported through [isCloud] and [cloudProvider] for the screen.
class RoutingEngine implements InferenceEngine {
  RoutingEngine({required this.local, required this.cloud});

  /// The on-device model (native once loaded, demo answers until then).
  final InferenceEngine local;
  final CloudEngine cloud;

  /// The coding mode: when it handles a request, two models share the work instead of the one
  /// in use. Null until the app sets it up.
  CodingEngine? coding;

  AiProvider? _cloudProvider;

  bool get isCloud => _cloudProvider != null;

  /// The provider in use, or null for the device model.
  AiProvider? get cloudProvider => _cloudProvider;

  /// Switches to [provider] (cloud), or to the device model when it is null.
  set target(AiProvider? provider) => _cloudProvider = provider;

  InferenceEngine get active => _cloudProvider == null ? local : cloud;

  @override
  bool get isLoaded => active.isLoaded;

  @override
  Future<void> load(LoadParams params) => local.load(params);

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) {
    final split = coding;
    if (split != null && split.handles(request)) return split.generate(request);
    return active.generate(request);
  }

  @override
  void cancel() {
    // Whichever is answering stops; the other one has nothing running.
    cloud.cancel();
    local.cancel();
    coding?.cancel();
  }

  @override
  Future<void> unload() => local.unload();
}
