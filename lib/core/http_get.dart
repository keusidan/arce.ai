import 'dart:async';

import 'package:http/http.dart' as http;

class HttpStatusException implements Exception {
  HttpStatusException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => message;
}

/// The only network primitive the core needs; tests substitute a fake.
typedef HttpGet = Future<String> Function(String url, Map<String, String> headers);

HttpGet packageHttpGet({http.Client? client, Duration timeout = const Duration(seconds: 20)}) {
  final c = client ?? http.Client();
  return (url, headers) async {
    final response = await c.get(Uri.parse(url), headers: {'User-Agent': 'ARCE.AI', ...headers}).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw HttpStatusException(response.statusCode, 'HTTP ${response.statusCode} for ${url.split('?').first}');
    }
    return response.body;
  };
}
