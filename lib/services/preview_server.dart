import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Serves generated HTML on 127.0.0.1 so it can be opened in the system browser on every
/// platform. The page runs in a sandboxed origin, so it cannot reach other local pages or
/// the app itself.
class PreviewServer {
  HttpServer? _server;
  final _pages = <String, String>{};
  int _next = 0;

  Future<Uri> publish(String html) async {
    final server = _server ??= await _start();
    final id = '${_next++}';
    _pages[id] = html;
    return Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: '/p/$id');
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final id = request.uri.pathSegments.length == 2 && request.uri.pathSegments.first == 'p'
          ? request.uri.pathSegments[1]
          : null;
      final html = id == null ? null : _pages[id];
      final response = request.response;
      if (html == null || request.method != 'GET') {
        response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }
      response
        ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
        ..headers.set('X-Content-Type-Options', 'nosniff')
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
