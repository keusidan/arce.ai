import '../ai/routing_engine.dart';
import '../core/engine.dart';
import '../core/generation.dart';

/// Who may use what only one chat can use at a time: the device model (one set of weights and one
/// KV cache) and the coding mode (which drives it). Online models are not shared like this.
class ExclusiveLease {
  Object? _owner;

  bool get isHeld => _owner != null;

  /// True when [owner] has the lease now (it already had it, or nobody did).
  bool acquire(Object owner) {
    if (_owner != null && _owner != owner) return false;
    _owner = owner;
    return true;
  }

  void release(Object owner) {
    if (_owner == owner) _owner = null;
  }
}

/// The engine of one chat. Several chats can generate at the same time (the others keep going in the
/// background while another one is on the screen), so a request must not stop, or be stopped by,
/// the request of another chat:
///
/// - an online model answers any number of chats at once; "stop" ends only this chat's stream;
/// - the device model and the coding mode answer one chat at a time. A second chat that asks
///   is told so, instead of mixing its prompt into the first one's cache.
class SessionEngine implements InferenceEngine {
  SessionEngine(this._router, this._lease);

  final RoutingEngine _router;
  final ExclusiveLease _lease;

  bool _cancelled = false;

  /// Whether the request in progress uses the device model or the coding mode.
  bool _exclusive = false;

  @override
  bool get isLoaded => _router.isLoaded;

  @override
  Future<void> load(LoadParams params) => _router.load(params);

  @override
  Future<void> unload() => _router.unload();

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    _cancelled = false;
    final split = _router.coding;
    _exclusive = !_router.isCloud || (split != null && split.handles(request));
    if (_exclusive && !_lease.acquire(this)) {
      throw EngineException('端末のモデル（または分担）を、ほかのチャットが使っています。そのチャットの生成が終わってから、もう一度送ってください');
    }
    try {
      var finished = false;
      await for (final event in _router.generate(request)) {
        // an online request is dropped here: its engine is shared, and is not told to stop
        if (_cancelled && !_exclusive) break;
        if (event is Finished) finished = true;
        yield event;
      }
      if (_cancelled && !_exclusive && !finished) yield const Finished(FinishReason.cancelled);
    } finally {
      if (_exclusive) _lease.release(this);
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    // only what this chat is using is stopped: stopping the shared online engine would end the
    // replies of the other chats too
    if (_exclusive) {
      _router.local.cancel();
      _router.coding?.cancel();
    }
  }
}
