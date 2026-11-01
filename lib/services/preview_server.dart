import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Serves generated HTML on 127.0.0.1 so it can be opened in the system browser on every
/// platform. The page runs in a sandboxed origin, so it cannot reach other local pages or
/// the app itself.
///
/// Any other app on the device can connect to a port on 127.0.0.1, so a page is reachable only by its
/// address, and the address holds 128 random bits (it used to be a counter: `/p/0`, `/p/1` ...,
/// which another app could simply walk through to read the code and text of every page). Requests
/// that name another host (a web page that makes its own name point at 127.0.0.1) are refused, and
/// only the newest [maxPages] pages are kept.
class PreviewServer {
  PreviewServer({this.maxPages = 50});

  /// How many pages are kept; the oldest goes when there are more.
  int maxPages;

  HttpServer? _server;
  final _pages = <String, String>{}; // keeps the order they were published in
  final _random = Random.secure();

  Future<Uri> publish(String html) async {
    final server = _server ??= await _start();
    final id = _newId();
    _pages[id] = html;
    while (_pages.length > (maxPages < 1 ? 1 : maxPages)) {
      _pages.remove(_pages.keys.first);
    }
    return Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: '/p/$id');
  }

  String _newId() => [for (var i = 0; i < 16; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final id = request.uri.pathSegments.length == 2 && request.uri.pathSegments.first == 'p'
          ? request.uri.pathSegments[1]
          : null;
      final html = id == null ? null : _pages[id];
      final response = request.response;
      if (html == null || request.method != 'GET' || request.headers.host != '127.0.0.1') {
        response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }
      response
        ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
        ..headers.set('X-Content-Type-Options', 'nosniff')
        ..headers.set('Cache-Control', 'no-store')
        ..headers.set('Referrer-Policy', 'no-referrer')
        // no allow-same-origin: the page gets an opaque origin of its own
        ..headers.set('Content-Security-Policy', 'sandbox allow-scripts allow-forms allow-modals allow-popups')
        ..add(utf8.encode(html))
        ..close();
    });
    return server;
  }

  Future<void> dispose() async {
    await _server?.close(force: true);
    _server = null;
    _pages.clear();
  }
}
