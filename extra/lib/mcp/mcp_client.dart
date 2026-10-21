import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One tool an MCP server offers, in the shape the chat can hand to a model.
class McpTool {
  const McpTool({required this.name, required this.description, required this.parameters});

  final String name;
  final String description;

  /// JSON Schema of the arguments, as the server published it.
  final Map<String, Object?> parameters;
}

class McpException implements Exception {
  McpException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A client for one MCP server over HTTP (the "Streamable HTTP" transport).
///
/// Every step is one JSON-RPC 2.0 POST; the answer is either a JSON body or an SSE stream whose
/// `data:` lines carry the messages. Only what the chat needs is implemented: `initialize`,
/// `tools/list` and `tools/call`, which is enough for the GitHub server and most others.
class McpClient {
  McpClient({
    required this.url,
    this.token = '',
    this.clientName = 'ARCE.AI',
    this.clientVersion = '0.6.0',
    http.Client? client,
    this.timeout = const Duration(seconds: 40),
  }) : _client = client ?? http.Client();

  final String url;

  /// Sent as `Authorization: Bearer <token>` when it is not empty.
  final String token;
  final String clientName;
  final String clientVersion;
  final Duration timeout;
  final http.Client _client;

  static const protocolVersion = '2025-06-18';

  int _nextId = 0;
  bool _initialized = false;

  Map<String, String> get headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
      };

  /// The tools the server publishes. The names are the server's own; the caller adds a prefix.
  Future<List<McpTool>> listTools() async {
    await _ensureInitialized();
    final result = await _request('tools/list', const {});
    final raw = result['tools'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map && item['name'] is String)
          McpTool(
            name: item['name'] as String,
            description: item['description'] is String ? item['description'] as String : '',
            parameters: _schema(item['inputSchema']),
          ),
    ];
  }

  /// Runs one tool. A failure the server reports is thrown as [McpException] with its text, so the
  /// chat can show it and tell the model.
  Future<String> callTool(String name, Map<String, Object?> arguments) async {
    await _ensureInitialized();
    final result = await _request('tools/call', {'name': name, 'arguments': arguments});
    final content = result['content'];
    final parts = <String>[
      if (content is List)
        for (final item in content)
          if (item is Map && item['type'] == 'text' && item['text'] is String) item['text'] as String,
    ];
    final text = parts.join('\n').trim();
    if (result['isError'] == true) throw McpException(text.isEmpty ? 'ツールが失敗しました' : text);
    return text.isEmpty ? jsonEncode(result) : text;
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _request('initialize', {
      'protocolVersion': protocolVersion,
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': clientName, 'version': clientVersion},
    });
    // The server expects this notification before any other request.
    await _post({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    _initialized = true;
  }

  Future<Map<String, Object?>> _request(String method, Map<String, Object?> params) async {
    final id = ++_nextId;
    final response = await _post({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    final message = pick(response.body, response.headers['content-type'] ?? '', id);
    if (message == null) throw McpException('$method の応答を読み取れませんでした');
    final error = message['error'];
    if (error is Map) {
      throw McpException(error['message'] is String ? error['message'] as String : '$error');
    }
    final result = message['result'];
    return result is Map ? result.cast<String, Object?>() : <String, Object?>{};
  }

  Future<http.Response> _post(Object body) async {
    final response = await _client
        .post(Uri.parse(url), headers: headers, body: jsonEncode(body))
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw McpException('サーバーが ${response.statusCode} を返しました');
    }
    return response;
  }

  /// Finds the answer with [id] in a JSON body or in an SSE stream.
  static Map<String, Object?>? pick(String body, String contentType, int id) {
    final candidates = <Object?>[];
    final trimmed = body.trim();
    final sse = contentType.contains('text/event-stream') ||
        trimmed.startsWith('event:') ||
        trimmed.startsWith('data:');
    if (sse) {
      for (final line in const LineSplitter().convert(body)) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        candidates.add(_decode(payload));
      }
    } else {
      candidates.add(_decode(trimmed));
    }
    for (final candidate in candidates) {
      if (candidate is Map && candidate['id'] == id) return candidate.cast<String, Object?>();
    }
    return null;
  }

  /// An object schema is what a tool call needs; a server that sends nothing usable gets an empty
  /// one, so the call can still be made.
  static Map<String, Object?> _schema(Object? raw) {
    if (raw is! Map) return const {'type': 'object', 'properties': <String, Object?>{}};
    final schema = raw.cast<String, Object?>();
    if (schema['type'] != 'object') {
      return {'type': 'object', 'properties': schema};
    }
    return schema;
  }

  static Object? _decode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  void close() => _client.close();
}
