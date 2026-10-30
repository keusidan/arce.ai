import 'dart:convert';

import 'package:arce_ai/ai/model_availability.dart';
import 'package:arce_ai/ai/model_info.dart';
import 'package:arce_ai/ai/model_tree.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/app.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:arce_ai/ui/model_detail_page.dart';
import 'package:arce_ai/ui/model_tree_view.dart';
import 'package:arce_ai/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'app_test.dart' show makeApp, setSize;

const _sse = 'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';

/// A Gemini key of the free tier: [answer] says what each model replies with.
const gemini = ProviderConfig(
  id: 'gem',
  label: 'Gemini',
  baseUrl: 'https://gemini.example/v1beta/openai',
  models: [ModelConfig(id: 'gemini-2.5-flash', name: 'flash'), ModelConfig(id: 'gemini-2.5-pro', name: 'pro')],
  catalog: [
    ModelInfo('gemini-2.5-flash'),
    ModelInfo('gemini-2.5-pro'),
    ModelInfo('gemini-1.0-pro'),
    ModelInfo('gemini-2.0-flash'),
    ModelInfo('text-embedding-004'),
  ],
);

typedef Reply = (int, String);

/// A scripted provider: the reply for a model, and the requests that came.
class Scripted {
  Scripted(this.replies);

  final Map<String, Reply> replies;
  final requests = <Map<String, Object?>>[];

  http.Client client() => MockClient.streaming((request, bodyStream) async {
        final body = utf8.decode(await bodyStream.expand((x) => x).toList());
        if (!request.url.path.endsWith('chat/completions')) {
          return http.StreamedResponse(Stream.value(utf8.encode('{"data":[]}')), 200, request: request);
        }
        final decoded = jsonDecode(body) as Map<String, Object?>;
        requests.add({...decoded, '_auth': request.headers['Authorization']});
        final (status, text) = replies[decoded['model']] ?? (200, _sse);
        return http.StreamedResponse(Stream.value(utf8.encode(text)), status, request: request);
      });
}

const _limit0 =
    '[{"error":{"code":429,"message":"You exceeded your current quota. * Quota exceeded for metric: generate_content_free_tier_requests, limit: 0, model: gemini-2.5-pro","status":"RESOURCE_EXHAUSTED"}}]';
const _notFound = '[{"error":{"code":404,"message":"models/gemini-1.0-pro is not found for API version v1beta","status":"NOT_FOUND"}}]';

Future<AppController> appWith(WidgetTester tester, Scripted script) async {
  final app = await makeApp(tester);
  app.providers.clientFactory = script.client;
  await app.providers.save(gemini);
  await tester.runAsync(() => app.providers.setKey('gem', 'sk-free-tier'));
  await app.providers.setActive('gem');
  return app;
}

void main() {
  group('the model list shows what is known', () {
    testWidgets('a model this key cannot use is greyed with its reason; a usable one is marked; an unchecked one says nothing', (tester) async {
      final model = ModelTrees.forProvider(
        gemini,
        marks: ModelMarks(
          lookup: (p, m) => switch (m) {
            'gemini-2.5-pro' => const AvailabilityRecord(ModelAvailability.blocked, 'このキー（無料枠）では、このモデルの利用枠が 0 です', 1),
            'gemini-2.5-flash' => const AvailabilityRecord(ModelAvailability.usable, '', 1),
            _ => null,
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: SingleChildScrollView(child: ModelTreeView(model: model, selectedKey: null, onPick: (_) {}, searching: true))),
        ),
      );
      expect(find.text('使えません：このキー（無料枠）では、このモデルの利用枠が 0 です'), findsOneWidget);
      expect(find.text('使えると確認済み'), findsOneWidget);
      expect(find.byKey(const ValueKey('model-blocked')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-usable')), findsOneWidget);
      // greyed, last in the folder
      final opacity = tester.widget<Opacity>(find.ancestor(of: find.text('gemini-2.5-pro'), matching: find.byType(Opacity)).first);
      expect(opacity.opacity, lessThan(1));
      final pro = tester.getTopLeft(find.text('gemini-2.5-pro')).dy;
      expect(pro, greaterThan(tester.getTopLeft(find.text('gemini-2.0-flash')).dy), reason: 'the unusable one is after the unchecked ones');
      final plain = tester.widget<Opacity>(find.ancestor(of: find.text('gemini-2.0-flash'), matching: find.byType(Opacity)).first);
      expect(plain.opacity, 1);
    });

    testWidgets('a greyed model can still be picked (a plan may have changed)', (tester) async {
      final model = ModelTrees.forProvider(gemini, marks: ModelMarks(lookup: (p, m) => m == 'gemini-2.5-pro' ? const AvailabilityRecord(ModelAvailability.blocked, 'r', 1) : null));
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: SingleChildScrollView(child: ModelTreeView(model: model, selectedKey: null, onPick: (k) => picked = k, searching: true))),
        ),
      );
      await tester.tap(find.text('gemini-2.5-pro'));
      expect(picked, 'gemini-2.5-pro');
    });
  });

  group('finding out from a real request', () {
    testWidgets('a "this key cannot use it" answer marks the model, says which one and what to do; another model is not marked; an answer takes the mark back', (tester) async {
      final script = Scripted({'gemini-2.5-pro': (429, _limit0)});
      final app = await appWith(tester, script);
      await tester.pumpWidget(ArceApp(app: app));
      await tester.pump();

      await app.providers.setActiveModel('gem', 'gemini-2.5-pro');
      await tester.runAsync(() => app.chat.send('こんにちは'));
      final error = app.chat.state.error!;
      expect(error, contains('Gemini の gemini-2.5-pro'));
      expect(error, contains('いまのキー（プラン）では使えないようです'));
      expect(error, contains('別のモデルを選んでください'));
      expect(error, contains('利用枠が 0'));
      final mark = app.availability.recordOf('gem', 'gemini-2.5-pro', trustDays: 7)!;
      expect(mark.isBlocked, isTrue);
      expect(app.modelMarks.of('gem', 'gemini-2.5-pro')!.isBlocked, isTrue);
      expect(app.availability.recordOf('gem', 'gemini-2.5-flash', trustDays: 7), isNull, reason: 'only the model that failed is marked');
      // the chat history does not carry the provider's body, only the shown message
      expect(error, isNot(contains('RESOURCE_EXHAUSTED')));

      // another model answers: nothing is marked for it
      await app.providers.setActiveModel('gem', 'gemini-2.5-flash');
      app.chat.clear();
      await tester.runAsync(() => app.chat.send('こんにちは'));
      expect(app.chat.state.error, isNull);
      expect(app.availability.recordOf('gem', 'gemini-2.5-flash', trustDays: 7), isNull, reason: 'an ordinary answer writes nothing');

      // the plan changes: the pro model answers, and the note is taken back
      script.replies.clear();
      await app.providers.setActiveModel('gem', 'gemini-2.5-pro');
      app.chat.clear();
      await tester.runAsync(() => app.chat.send('もう一度'));
      expect(app.chat.state.error, isNull);
      expect(app.availability.recordOf('gem', 'gemini-2.5-pro', trustDays: 7)!.isUsable, isTrue);
    });

    testWidgets('a limit that passes, or a refused key, marks nothing', (tester) async {
      final script = Scripted({
        'gemini-2.5-flash': (429, '{"error":{"message":"Quota exceeded for metric x, limit: 5. Please retry in 12s."}}'),
        'gemini-2.5-pro': (401, '{"error":{"message":"Incorrect API key provided"}}'),
      });
      final app = await appWith(tester, script);
      await tester.pumpWidget(ArceApp(app: app));
      await tester.pump();
      await tester.runAsync(() => app.chat.send('a'));
      expect(app.chat.state.error, isNotNull);
      expect(app.chat.state.error, isNot(contains('使えないようです')));
      app.chat.clear();
      await app.providers.setActiveModel('gem', 'gemini-2.5-pro');
      await tester.runAsync(() => app.chat.send('b'));
      expect(app.chat.state.error, contains('APIキー'));
      expect(app.availability.length, 0);
    });

    testWidgets('with the setting off nothing is marked, but the message still says which model cannot be used', (tester) async {
      final script = Scripted({'gemini-2.5-flash': (429, _limit0)});
      final app = await appWith(tester, script);
      await app.settings.update((s) => s.copyWith(markBlockedModels: false));
      await tester.pumpWidget(ArceApp(app: app));
      await tester.pump();
      await tester.runAsync(() => app.chat.send('a'));
      expect(app.chat.state.error, contains('gemini-2.5-flash'));
      expect(app.chat.state.error, isNot(contains('印が付きました')));
      expect(app.availability.length, 0);
    });
  });

  group('the probe', () {
    testWidgets('asks one word of each chat model, marks what it learns, and skips what is not a chat model', (tester) async {
      final script = Scripted({'gemini-2.5-pro': (429, _limit0), 'gemini-1.0-pro': (404, _notFound), 'gemini-2.0-flash': (503, '{"error":{"message":"overloaded"}}')});
      final app = await appWith(tester, script);
      final ids = app.probeCandidates(gemini.knownIds);
      expect(ids, isNot(contains('text-embedding-004')));
      expect(ids, hasLength(4));

      late String summary;
      await tester.runAsync(() async => summary = await app.probeModels('gem', ids));
      expect(summary, '4 個を確かめました：使える 1・使えない 2・一時的な失敗 1（あとでもう一度）');
      expect(script.requests.map((r) => r['model']).toSet(), ids.toSet(), reason: 'every chat model was asked, once');
      expect(script.requests.every((r) => r['model'] != 'text-embedding-004'), isTrue);
      for (final r in script.requests) {
        expect(r['max_tokens'], 1);
        expect(r.containsKey('tools'), isFalse);
        expect((r['messages']! as List).single, {'role': 'user', 'content': 'hi'});
        expect(r['_auth'], 'Bearer sk-free-tier');
      }
      expect(app.modelMarks.of('gem', 'gemini-2.5-flash')!.isUsable, isTrue);
      expect(app.modelMarks.of('gem', 'gemini-2.5-pro')!.isBlocked, isTrue);
      expect(app.modelMarks.of('gem', 'gemini-1.0-pro')!.isBlocked, isTrue);
      expect(app.modelMarks.of('gem', 'gemini-2.0-flash'), isNull, reason: 'a busy server says nothing about the key');
      expect(app.isProbing('gem'), isFalse);
    });

    testWidgets('a refused key stops it: nothing is marked', (tester) async {
      final script = Scripted({for (final id in ['gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-1.0-pro', 'gemini-2.0-flash']) id: (401, '{"error":{"message":"Incorrect API key provided"}}')});
      final app = await appWith(tester, script);
      await app.settings.update((s) => s.copyWith(modelProbeConcurrency: 1));
      late String summary;
      await tester.runAsync(() async => summary = await app.probeModels('gem', app.probeCandidates(gemini.knownIds)));
      expect(summary, contains('APIキーが受け付けられなかった'));
      expect(script.requests, hasLength(1), reason: 'one at a time: the first refusal ends it');
      expect(app.availability.length, 0);
    });

    testWidgets('a provider that is not there, nothing to ask, and a second probe at the same time', (tester) async {
      final app = await appWith(tester, Scripted({}));
      expect(await app.probeModels('nobody', ['m']), 'プロバイダが見つかりません');
      expect(await app.probeModels('gem', const []), '確かめるモデルがありません');
    });

    testWidgets('the setting for concurrency is the one used', (tester) async {
      var running = 0;
      var most = 0;
      final app = await makeApp(tester);
      app.providers.clientFactory = () => MockClient.streaming((request, bodyStream) async {
            await bodyStream.drain<void>();
            running++;
            if (running > most) most = running;
            await Future<void>.delayed(const Duration(milliseconds: 10));
            running--;
            return http.StreamedResponse(Stream.value(utf8.encode(_sse)), 200, request: request);
          });
      await app.providers.save(gemini);
      await app.settings.update((s) => s.copyWith(modelProbeConcurrency: 2));
      await tester.runAsync(() => app.probeModels('gem', ['a', 'b', 'c', 'd', 'e', 'f']));
      expect(most, 2);
    });
  });

  group('on the screen', () {
    testWidgets('the models sheet: the button asks first and says how many; after it the marks are on the list', (tester) async {
      setSize(tester, const Size(411, 1000));
      final script = Scripted({'gemini-2.5-pro': (429, _limit0)});
      final app = await appWith(tester, script);
      await tester.pumpWidget(ArceApp(app: app));
      await tester.pump();
      app.openSettings(SettingsSection.providers);
      await tester.pumpAndSettle();
      await tester.tap(find.text('モデル').first);
      await tester.pumpAndSettle();

      expect(find.text('使えるか確かめる'), findsOneWidget);
      await tester.tap(find.text('使えるか確かめる'));
      await tester.pumpAndSettle();
      // asked first: how many, what it costs, what is kept
      expect(find.textContaining('4 個のモデルに'), findsOneWidget);
      expect(find.textContaining('回数制限'), findsWidgets);
      expect(find.textContaining('埋め込み・音声・画像などのモデル 1 個は除きます'), findsOneWidget);
      expect(script.requests, isEmpty, reason: 'nothing is sent before the user says so');

      // not now
      await tester.tap(find.text('やめる'));
      await tester.pumpAndSettle();
      expect(script.requests, isEmpty);

      await tester.tap(find.text('使えるか確かめる'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('確かめる'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(script.requests, hasLength(4));
      expect(find.textContaining('使える 3・使えない 1'), findsOneWidget);

      // with a search, every folder is open: the marks are in sight
      await tester.enterText(find.byType(TextField).first, 'gemini');
      await tester.pumpAndSettle();
      expect(find.textContaining('使えません：'), findsOneWidget);
      expect(find.text('使えると確認済み'), findsWidgets);
    });

    testWidgets('the search narrows what the button asks', (tester) async {
      setSize(tester, const Size(411, 1000));
      final script = Scripted({});
      final app = await appWith(tester, script);
      await tester.pumpWidget(ArceApp(app: app));
      await tester.pump();
      app.openSettings(SettingsSection.providers);
      await tester.pumpAndSettle();
      await tester.tap(find.text('モデル').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'pro');
      await tester.pumpAndSettle();
      await tester.tap(find.text('使えるか確かめる'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 個のモデルに'), findsOneWidget);
      expect(find.textContaining('検索で絞った分だけです'), findsOneWidget);
    });

    testWidgets('the settings: the switches and the numbers are there, and change the settings; the marks can be cleared', (tester) async {
      setSize(tester, const Size(411, 2600));
      final app = await appWith(tester, Scripted({}));
      await app.availability.record('gem', 'gemini-2.5-pro', const AvailabilityVerdict(ModelAvailability.blocked, 'r'), trustDays: 7);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: ModelDetailPage(app: app)));
      await tester.pumpAndSettle();

      expect(find.text('使えるモデルの確認'), findsOneWidget);
      expect(find.text('使えないと分かったモデルを、選択肢から隠す'), findsOneWidget);
      expect(find.text('送信で使えないと分かったら、印を付ける'), findsOneWidget);
      expect(find.text('7 日'), findsOneWidget);
      expect(find.text('30 秒'), findsOneWidget);
      expect(app.settings.value.hideUnusableModels, isFalse);
      await tester.tap(find.text('7 日'));
      await tester.pump();
      expect(app.settings.value.modelAvailabilityTrustDays, 14);
      await tester.tap(find.text('30 秒'));
      await tester.pump();
      expect(app.settings.value.modelProbeTimeoutSeconds, 60);

      expect(find.textContaining('（1 件）'), findsOneWidget);
      await tester.tap(find.text('消す'));
      await tester.pumpAndSettle();
      expect(app.availability.length, 0);
    });
  });

  group('hiding', () {
    testWidgets('with the setting on, the models the lists know to be unusable are left out, the one in use stays', (tester) async {
      final app = await appWith(tester, Scripted({}));
      await app.availability.record('gem', 'gemini-1.0-pro', const AvailabilityVerdict(ModelAvailability.blocked, 'r'), trustDays: 7);
      await app.availability.record('gem', 'gemini-2.5-pro', const AvailabilityVerdict(ModelAvailability.blocked, 'r'), trustDays: 7);
      List<String> shown({String? keep}) => [
            for (final n in ModelTrees.forProvider(gemini, marks: app.modelMarks, keepKey: keep).nodes) ...n.leaves.map((l) => l.key),
          ];
      expect(shown(), containsAll(['gemini-1.0-pro', 'gemini-2.5-pro']), reason: 'shown, greyed, by default');
      await app.settings.update((s) => s.copyWith(hideUnusableModels: true));
      expect(shown(), isNot(contains('gemini-1.0-pro')));
      expect(shown(), isNot(contains('gemini-2.5-pro')));
      expect(shown(keep: 'gemini-2.5-pro'), contains('gemini-2.5-pro'));
      // and a mark is only believed for the days set
      await app.settings.update((s) => s.copyWith(hideUnusableModels: false));
      expect(app.modelMarks.of('gem', 'gemini-1.0-pro'), isNotNull);
    });

    testWidgets('a removed provider takes its marks with it', (tester) async {
      final app = await appWith(tester, Scripted({}));
      await app.availability.record('gem', 'gemini-2.5-pro', const AvailabilityVerdict(ModelAvailability.blocked, 'r'), trustDays: 7);
      expect(app.availability.length, 1);
      // removing a provider also clears its key in the secure storage (a platform channel: the real event loop)
      await tester.runAsync(() async {
        await app.providers.remove('gem');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(app.availability.length, 0);
    });
  });
}
