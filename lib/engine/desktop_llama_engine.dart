import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../core/engine.dart';
import '../core/generation.dart';

/// Windows/Linux implementation of the same llama.cpp flow used by Android. The shared library
/// is bundled by the platform CMake files; opening it is intentionally delayed until a model is
/// selected, so the rest of the UI still starts and can show a useful error if a custom install
/// lost its native files.
class DesktopLlamaEngine implements InferenceEngine {
  DesktopLlamaEngine();

  static bool get isSupportedPlatform => Platform.isWindows || Platform.isLinux;

  _DesktopBindings? _bindings;
  Pointer<Void> _engine = nullptr;
  bool _cancelled = false;

  _DesktopBindings get _native {
    final current = _bindings;
    if (current != null) return current;
    final loaded = _DesktopBindings(_openLibrary());
    loaded.backendInit();
    _bindings = loaded;
    return loaded;
  }

  DynamicLibrary _openLibrary() {
    final executable = File(Platform.resolvedExecutable).parent.path;
    final names = Platform.isWindows
        ? <String>['$executable${Platform.pathSeparator}arce_llama.dll', 'arce_llama.dll']
        : <String>[
            '$executable${Platform.pathSeparator}lib${Platform.pathSeparator}libarce_llama.so',
            '$executable${Platform.pathSeparator}libarce_llama.so',
            'libarce_llama.so',
          ];
    Object? last;
    for (final name in names) {
      try {
        return DynamicLibrary.open(name);
      } catch (e) {
        last = e;
      }
    }
    throw EngineException('llama.cpp の共有ライブラリを開けません: $last');
  }

  @override
  bool get isLoaded => _engine != nullptr;

  String? get backendName => isLoaded ? 'llama.cpp' : null;

  Future<List<String>> devices() async => isSupportedPlatform ? const ['CPU: llama.cpp'] : const [];

  @override
  Future<void> load(LoadParams params) async {
    await unload();
    final native = _native;
    final path = params.path.toNativeUtf8();
    try {
      _engine = native.load(
        path,
        params.contextLength,
        params.threads,
        params.batchSize,
        params.gpuLayers,
        params.kvCache == KvCacheType.q8_0 ? 1 : 0,
      );
    } finally {
      calloc.free(path);
    }
    if (_engine == nullptr) throw EngineException(_error(native));
  }

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    if (!isLoaded) throw EngineException('モデルが読み込まれていません');
    final native = _native;
    _cancelled = false;
    final prompt = request.prompt.toNativeUtf8();
    final tools = request.toolCallSchema?.toNativeUtf8() ?? nullptr;
    final strict = request.strictJsonSchema?.toNativeUtf8() ?? nullptr;
    Pointer<Void> session = nullptr;
    try {
      session = native.start(
        _engine,
        prompt,
        tools,
        strict,
        request.thinking ? 1 : 0,
        request.maxTokens,
        request.sampling.temperature,
        request.sampling.topP,
        request.sampling.topK,
        request.sampling.minP,
        request.sampling.dryMultiplier,
      );
      if (session == nullptr) throw EngineException(_error(native));
      while (true) {
        final piece = native.next(session);
        if (piece == nullptr) break;
        final text = piece.toDartString();
        if (text.isNotEmpty) yield Piece(text);
        // Native token sampling is synchronous. Yielding here lets Flutter paint streamed text
        // between tokens without moving the model handle to a different isolate.
        await Future<void>.delayed(Duration.zero);
      }
      yield Finished(_reason(native.finishReason(session)));
    } finally {
      calloc.free(prompt);
      if (tools != nullptr) calloc.free(tools);
      if (strict != nullptr) calloc.free(strict);
      if (session != nullptr) native.end(session);
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    if (_engine != nullptr && _bindings != null) _bindings!.cancel(_engine);
  }

  @override
  Future<void> unload() async {
    if (_engine != nullptr && _bindings != null) _bindings!.free(_engine);
    _engine = nullptr;
    _cancelled = false;
  }

  String _error(_DesktopBindings native) {
    final message = native.lastError();
    return message == nullptr ? 'llama.cpp の推論に失敗しました' : message.toDartString();
  }

  FinishReason _reason(int value) => switch (value) {
        0 => FinishReason.eog,
        1 => FinishReason.length,
        2 => FinishReason.cancelled,
        _ => _cancelled ? FinishReason.cancelled : FinishReason.error,
      };
}

class _DesktopBindings {
  _DesktopBindings(DynamicLibrary library)
      : backendInit = library.lookupFunction<_BackendInitNative, _BackendInitDart>('arce_backend_init'),
        lastError = library.lookupFunction<_LastErrorNative, _LastErrorDart>('arce_last_error'),
        load = library.lookupFunction<_LoadNative, _LoadDart>('arce_load'),
        free = library.lookupFunction<_FreeNative, _FreeDart>('arce_free'),
        cancel = library.lookupFunction<_CancelNative, _CancelDart>('arce_cancel'),
        start = library.lookupFunction<_StartNative, _StartDart>('arce_start'),
        next = library.lookupFunction<_NextNative, _NextDart>('arce_next'),
        finishReason = library.lookupFunction<_FinishNative, _FinishDart>('arce_finish_reason'),
        end = library.lookupFunction<_EndNative, _EndDart>('arce_end');

  final _BackendInitDart backendInit;
  final _LastErrorDart lastError;
  final _LoadDart load;
  final _FreeDart free;
  final _CancelDart cancel;
  final _StartDart start;
  final _NextDart next;
  final _FinishDart finishReason;
  final _EndDart end;
}

typedef _BackendInitNative = Void Function();
typedef _BackendInitDart = void Function();
typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();
typedef _LoadNative = Pointer<Void> Function(Pointer<Utf8>, Int32, Int32, Int32, Int32, Uint8);
typedef _LoadDart = Pointer<Void> Function(Pointer<Utf8>, int, int, int, int, int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _CancelNative = Void Function(Pointer<Void>);
typedef _CancelDart = void Function(Pointer<Void>);
typedef _StartNative = Pointer<Void> Function(
  Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Uint8, Int32, Float, Float, Int32, Float, Float,
);
typedef _StartDart = Pointer<Void> Function(
  Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, int, double, double, int, double, double,
);
typedef _NextNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _NextDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _FinishNative = Int32 Function(Pointer<Void>);
typedef _FinishDart = int Function(Pointer<Void>);
typedef _EndNative = Void Function(Pointer<Void>);
typedef _EndDart = void Function(Pointer<Void>);
