import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/generation.dart';
import 'model_info.dart';
import 'provider.dart';
import 'provider_config.dart';

/// A provider that speaks the OpenAI chat-completions protocol, which is what almost every cloud
/// API and local server (Ollama, LM Studio, LMDeploy, vLLM, OpenRouter, ...) offers as well.
///
/// Differences between services are handled by the two overrides: extra [headers] and extra
/// [body] fields, which are sent last so they win over the generated ones.
///
/// The adapter owns the SSE details (events split across chunks, tool-call arguments arriving in
/// fragments) and emits one [ToolCallDelta] per call only when it is complete.
class OpenAiCompatibleProvider implements AiProvider {
  OpenAiCompatibleProvider({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.model,
    this.modelConfig,
    this.apiKey = '',
    this.headers = const {},
    this.body = const {},
    this.supportsTools = true,
    http.Client? client,
    this.timeout = const Duration(seconds: 120),
  }) : _client = client ?? http.Client();

  @override
  final String id;

  @override
  final String label;

  @override
  String get modelId => model;

  @override
  final ModelConfig? modelConfig;

  /// Everything before `/chat/completions`, e.g. `https://api.openai.com/v1`.
  final String baseUrl;
  final String model;


  final String apiKey;
  final Map<String, String> headers;
  final Map<String, Object?> body;
  final Duration timeout;

  /// Whether the endpoint offers function calling. A model without tools still answers; it just
  /// cannot call one.
  final bool supportsTools;

  final http.Client _client;

  @override
  ProviderCapabilities get capabilities =>
      ProviderCapabilities(
        tools: supportsTools,
        reasoning: true,
        vision: modelConfig?.supportsImages ?? ModelConfig.guessVision(model),
        usage: true,
      );

  Uri _uri(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/$path');

  Map<String, String> get _requestHeaders => {
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream',
    if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    ...headers,
  };

  @override
  Stream<Delta> stream(AiRequest request) async* {
    final message = http.Request('POST', _uri('chat/completions'))
      ..headers.addAll(_requestHeaders)
      ..body = jsonEncode(_body(request));

    final response = await _client.send(message).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw AiProviderException(
        _failure(response.statusCode, await response.stream.bytesToString()),
      );
    }

    final calls = <int, _PartialCall>{};
    var finish = FinishReason.eog;
    final decoder = const Utf8Decoder();
    var pending = '';

    await for (final bytes in response.stream) {
      pending += decoder.convert(bytes);
      // events end with a blank line; keep the last unfinished line for the next chunk
      final lines = pending.split('\n');
      pending = lines.removeLast();
      for (final raw in lines) {
        final line = raw.trimRight();
        if (line.isEmpty || line.startsWith(':')) continue;
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;

        final Object? decoded;
        try {
          decoded = jsonDecode(data);
        } catch (_) {
          continue; // a keep-alive or a provider-specific event
        }
        if (decoded is! Map) continue;

        final usage = decoded['usage'];
        if (usage is Map) {
          final prompt = _int(usage['prompt_tokens']);
          final completion = _int(usage['completion_tokens']);
          if (prompt != null || completion != null) {
            yield UsageDelta(
              promptTokens: prompt,
              completionTokens: completion,
            );
          }
        }

        final choices = decoded['choices'];
        final choice = choices is List && choices.isNotEmpty
            ? choices.first
            : null;
        if (choice is! Map) continue;

        final delta = choice['delta'];
        if (delta is Map) {
          final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
          if (reasoning is String && reasoning.isNotEmpty) {
            yield ReasoningDelta(reasoning);
          }
          final text = delta['content'];
          if (text is String && text.isNotEmpty) yield TextDelta(text);
          for (final call in (delta['tool_calls'] as List? ?? const [])) {
            if (call is! Map) continue;
            final index = _int(call['index']) ?? 0;
            final partial = calls.putIfAbsent(index, _PartialCall.new);
            if (call['id'] is String) partial.id = call['id'] as String;
            final function = call['function'];
            if (function is Map) {
              final name = function['name'];
              if (name is String && name.isNotEmpty) partial.name = name;
              final arguments = function['arguments'];
              // arguments arrive in fragments and can be cut anywhere inside a string
              if (arguments is String) partial.arguments.write(arguments);
            }
          }
        }

        final reason = choice['finish_reason'];
        if (reason is String) finish = _finishOf(reason);
      }
    }

    for (final index in calls.keys.toList()..sort()) {
      final call = calls[index]!;
      if (call.name.isEmpty) continue;
      yield ToolCallDelta(
        id: call.id,
        name: call.name,
        argumentsJson: call.arguments.isEmpty
            ? '{}'
            : call.arguments.toString(),
      );
    }
    yield StopDelta(finish);
  }

  Map<String, Object?> _body(AiRequest request) => {
    'model': request.model.trim().isEmpty ? model : request.model,
    'messages': [for (final message in request.messages) _message(message)],
    'stream': true,
    'stream_options': {'include_usage': true},
    'max_tokens': request.maxTokens,
    'temperature': request.temperature,
    'top_p': request.topP,
    if (request.tools.isNotEmpty && supportsTools)
      'tools': [
        for (final tool in request.tools)
          {
            'type': 'function',
            'function': {
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
          },
      ],
    // the user's overrides come last, so a provider that needs different field names wins
    ...body,
  };

  static Map<String, Object?> _message(AiMessage message) {
    switch (message.role) {
      case AiRole.tool:
        return {
          'role': 'tool',
          'content': message.text,
          'tool_call_id': message.toolCallId,
        };
      case AiRole.system:
        return {'role': 'system', 'content': message.text};
      case AiRole.user:
        if (message.images.isEmpty) return {'role': 'user', 'content': message.text};
        return {
          'role': 'user',
          'content': [
            if (message.text.isNotEmpty) {'type': 'text', 'text': message.text},
            for (final image in message.images)
              {
                'type': 'image_url',
                'image_url': {'url': image.dataUrl},
              },
          ],
        };
      case AiRole.assistant:
        if (message.toolCalls.isEmpty) {
          return {'role': 'assistant', 'content': message.text};
        }
        return {
          'role': 'assistant',
          'content': message.text,
          'tool_calls': [
            for (final call in message.toolCalls)
              {
                'id': call.id,
                'type': 'function',
                'function': {
                  'name': call.name,
                  'arguments': call.argumentsJson,
                },
              },
          ],
        };
    }
  }

  /// The model names the endpoint offers, for the settings screen's "取得" button.
  Future<List<String>> listModels() async => [for (final info in await fetchModelInfos()) info.id];

  /// The models the endpoint offers, with whatever it says about each one's limits and abilities
  /// (see [ModelInfoParser] for the fields that are read). Sorted by id.
  Future<List<ModelInfo>> fetchModelInfos() async {
    final response = await _client
        .get(
          _uri('models'),
          headers: {..._requestHeaders, 'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw AiProviderException(_failure(response.statusCode, response.body));
    }
    try {
      return ModelInfoParser.parseList(jsonDecode(response.body))..sort((a, b) => a.id.compareTo(b.id));
    } catch (_) {
      throw const AiProviderException('モデル一覧を読み取れませんでした');
    }
  }

  @override
  Future<void> verify() async {
    final response = await _client
        .get(
          _uri('models'),
          headers: {..._requestHeaders, 'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw AiProviderException(_failure(response.statusCode, response.body));
    }
  }

  String _failure(int status, String body) {
    final message = _errorMessage(body);
    final detail = message == null ? '' : ': $message';
    return switch (status) {
      401 || 403 => 'APIキーが受け付けられませんでした（HTTP $status）$detail',
      404 => '接続先が見つかりません（HTTP 404）。URL とモデル名を確認してください$detail',
      429 => '回数制限に達しました（HTTP 429）。少し待ってからやり直してください',
      _ => 'プロバイダが失敗しました（HTTP $status）$detail',
    };
  }

  /// The `error.message` of a failed request, when the service sends one.
  static String? _errorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
        if (error is String) return error;
        if (decoded['message'] is String) return decoded['message'] as String;
      }
    } catch (_) {
      // not JSON: show the start of the body instead
      final text = body.trim();
      if (text.isNotEmpty) {
        return text.length > 200 ? text.substring(0, 200) : text;
      }
    }
    return null;
  }

  static FinishReason _finishOf(String reason) => switch (reason) {
    'length' => FinishReason.length,
    'content_filter' => FinishReason.error,
    _ => FinishReason.eog,
  };

  static int? _int(Object? value) =>
      value is int ? value : (value is num ? value.toInt() : null);
}

/// One tool call while its name and arguments are still arriving.
class _PartialCall {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
