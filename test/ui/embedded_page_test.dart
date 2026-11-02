import 'dart:convert';
import 'dart:io';

import 'package:arce_ai/app.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:arce_ai/ui/embedded_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show makeApp, setSize;

/// A reply that holds code blocks, put on the screen as the model's last message.
Future<AppController> showing(WidgetTester tester, String reply) async {
  setSize(tester, const Size(411, 860));
  final app = await makeApp(tester);
  await tester.pumpWidget(ArceApp(app: app));
  await tester.pump();
  app.chat.restore(
    ConversationSnapshot(
      messages: [
        const UiMessage(id: 0, role: Role.user, text: '作って'),
        UiMessage(id: 1, role: Role.assistant, text: reply),
      ],
      history: const [],
      nextId: 2,
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  return app;
}

const _html = '```html\n<h1>こんにちは</h1><script>document.title="x"</script>\n```';

void main() {
  tearDown(() => EmbeddedPage.builder = null);

  testWidgets('an HTML block has a button that shows the page inside the chat, and another that closes it', (tester) async {
    final shown = <Uri>[];
    EmbeddedPage.builder = (context, address, height) {
      shown.add(address);
      return SizedBox(key: const ValueKey('page'), height: height, child: Text('PAGE ${address.path.length}'));
    };
    final app = await showing(tester, _html);
    expect(find.byKey(const ValueKey('page')), findsNothing, reason: 'nothing is drawn until it is asked for');
    expect(find.text('表示'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('表示'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('page')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('page'))).height, 360, reason: 'the default height');
    final address = shown.last;
    expect((address.scheme, address.host), ('http', '127.0.0.1'), reason: 'the page is served by the app on this device only');
    expect(address.pathSegments.first, 'p');
    expect(address.pathSegments.last, matches(RegExp(r'^[0-9a-f]{32}$')), reason: 'an address no other app can guess');

    // the page is the code, served with the sandbox that gives it an origin of its own
    final text = await tester.runAsync(() async {
      HttpOverrides.global = null; // the test binding answers every request with 400: this one is the real local server
      final client = HttpClient();
      final request = await client.getUrl(address);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final sandbox = response.headers.value('content-security-policy');
      client.close();
      return (body, sandbox);
    });
    expect(text!.$1, contains('<h1>こんにちは</h1>'));
    expect(text.$2, allOf(contains('sandbox'), isNot(contains('allow-same-origin'))));

    expect(find.text('閉じる'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('page')), findsNothing);
    await tester.runAsync(app.preview.dispose);
  });

  testWidgets('an SVG block is shown in a plain page; another language has no such button', (tester) async {
    Uri? address;
    EmbeddedPage.builder = (context, uri, height) {
      address = uri;
      return const SizedBox(key: ValueKey('page'), height: 10);
    };
    final app = await showing(tester, '```svg\n<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><circle cx="20" cy="20" r="18"/></svg>\n```\n\n```python\nprint(1)\n```');
    expect(find.text('表示'), findsOneWidget, reason: 'the svg block only');
    await tester.runAsync(() async {
      await tester.tap(find.text('表示'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 100));
    final body = await tester.runAsync(() async {
      HttpOverrides.global = null;
      final client = HttpClient();
      final response = await (await client.getUrl(address!)).close();
      final text = await response.transform(utf8.decoder).join();
      client.close();
      return text;
    });
    expect(body, allOf(contains('<!doctype html>'), contains('<circle'), contains('charset="utf-8"')));
    await tester.runAsync(app.preview.dispose);
  });

  testWidgets('the height is a setting, and 0 leaves the button out', (tester) async {
    EmbeddedPage.builder = (context, uri, height) => SizedBox(key: const ValueKey('page'), height: height);
    final app = await showing(tester, _html);
    await app.settings.update((s) => s.copyWith(inlinePreviewHeight: 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('表示'), findsNothing);
    expect(find.text('ブラウザ'), findsOneWidget, reason: 'the browser button stays');
    await app.settings.update((s) => s.copyWith(inlinePreviewHeight: 480));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      await tester.tap(find.text('表示'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getSize(find.byKey(const ValueKey('page'))).height, 480);
    await tester.runAsync(app.preview.dispose);
  });
}
