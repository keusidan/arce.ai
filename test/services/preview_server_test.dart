import 'dart:convert';
import 'dart:io';

import 'package:arce_ai/services/preview_server.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(int, String, HttpHeaders)> get(Uri uri, {String? host, String method = 'GET'}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    if (host != null) request.headers.host = host;
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    return (response.statusCode, body, response.headers);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late PreviewServer server;
  setUp(() => server = PreviewServer());
  tearDown(() => server.dispose());

  test('a page is served at an address nobody can guess, with the headers that keep it in its own box', () async {
    final uri = await server.publish('<h1>こんにちは</h1>');
    expect(RegExp(r'^/p/[0-9a-f]{32}$').hasMatch(uri.path), isTrue, reason: '128 random bits, not a counter');
    final (status, body, headers) = await get(uri);
    expect(status, 200);
    expect(body, '<h1>こんにちは</h1>');
    expect(headers.value('content-security-policy'), startsWith('sandbox '));
    expect(headers.value('content-security-policy'), isNot(contains('allow-same-origin')));
    expect(headers.value('cache-control'), 'no-store');
    expect(headers.value('referrer-policy'), 'no-referrer');
    expect(headers.value('x-content-type-options'), 'nosniff');
  });

  test('walking through the old counter addresses finds nothing, and the addresses of two pages differ', () async {
    final a = await server.publish('A');
    final b = await server.publish('B');
    expect(a.path, isNot(b.path));
    for (final guess in ['0', '1', '2', 'a', '../p/0']) {
      final (status, _, _) = await get(a.replace(path: '/p/$guess'));
      expect(status, 404, reason: guess);
    }
    expect((await get(a.replace(path: '/')) ).$1, 404);
    expect((await get(a, method: 'POST')).$1, 404, reason: 'only GET');
  });

  test('a request that names another host (a web page pointing its own name at 127.0.0.1) is refused', () async {
    final uri = await server.publish('secret');
    final (status, body, _) = await get(uri, host: 'evil.example');
    expect(status, 404);
    expect(body, isNot(contains('secret')));
  });

  test('only the newest pages are kept', () async {
    server.maxPages = 2;
    final first = await server.publish('1');
    final second = await server.publish('2');
    final third = await server.publish('3');
    expect((await get(first)).$1, 404, reason: 'the oldest is gone');
    expect((await get(second)).$2, '2');
    expect((await get(third)).$2, '3');
  });
}
