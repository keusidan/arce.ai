import 'dart:io';

import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/thinking_config.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/releases.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:arce_ai/services/settings.dart';
import 'package:arce_ai/services/update_service.dart';
import 'package:arce_ai/app.dart';
import 'package:arce_ai/ui/provider_widgets.dart';
import 'package:arce_ai/ui/theme.dart';
import 'package:arce_ai/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppController> makeApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    // no network in tests: skip the automatic update check
    'settings.v1': '{"autoUpdateCheck":false}',
  });
  late AppController app;
  late Directory dir;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('arce_ui_test');
    final settings = await SettingsStore.load();
    app = await AppController.create(
      supportDirectory: dir,
      updateService: UpdateService(settings, currentVersion: const Version(0, 4, 0)),
    );
  });
  addTearDown(() async {
    // Close the database before removing the folder: Windows will not delete a file that is still
    // open (Linux allows it), which is why only the Windows runner failed these three tests.
    app.history.close();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // a handle can outlive close() for a moment; the system cleans the temp folder
    }
  });
  return app;
}

void setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('phone layout: welcome screen, bottom bar, and a demo reply', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(find.text('ARCE.AI へようこそ'), findsOneWidget);
    expect(find.text('生成物'), findsOneWidget, reason: 'bottom navigation');
    expect(find.text('ダークモード'), findsNothing, reason: 'no sidebar on a phone');

    await tester.enterText(find.byType(TextField), 'こんにちは');
    await tester.pump();
    await tester.tap(find.text('送信'));
    await tester.pump();
    // the demo engine streams a few characters at a time
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.textContaining('受け取りました', findRichText: true), findsWidgets);
    expect(app.chat.state.messages.length, 2);
    expect(find.text('こんにちは'), findsWidgets);
  });

  testWidgets('desktop layout: sidebar with navigation, and dark mode switch', (tester) async {
    setSize(tester, const Size(1280, 800));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(find.text('ダークモード'), findsOneWidget);
    expect(find.text('ローカルAIインストール'), findsOneWidget);

    await tester.tap(find.text('モデル管理').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(app.page, AppPage.models);
    expect(find.text('このOSでは推論エンジンが未対応です'), findsOneWidget);

    await app.settings.update((s) => s.copyWith(theme: ThemeMode.dark));
    await tester.pump(); // builds the frame that starts the theme animation
    await tester.pump(const Duration(milliseconds: 500));
    final context = tester.element(find.byType(Scaffold).first);
    expect(Theme.of(context).brightness, Brightness.dark);
  });

  testWidgets('settings page: a group opens under its row and shows only its own settings', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.goTo(AppPage.settings);
    await tester.pumpAndSettle();
    expect(find.text('Thinking 表示'), findsNothing, reason: 'every group starts closed');

    await tester.tap(find.text('モデル全般設定').first);
    await tester.pumpAndSettle();
    expect(find.text('Thinking 表示'), findsOneWidget);
    expect(find.text('HyperLoad'), findsNothing, reason: 'the local model group is not mixed in');
    expect(find.text('Context Length'), findsNothing);
    expect(find.text('口調'), findsOneWidget, reason: 'the answer settings are common to both kinds of model, so they are here');
    expect(find.text('最大トークン数（共通）'), findsOneWidget);
    expect(find.text('SearXNG のアドレス'), findsNothing, reason: 'search has a group of its own');
    expect(find.text('ローカルモデルの設定'), findsOneWidget, reason: 'the other rows are still listed');

    // opening another group folds the first
    await tester.tap(find.text('ローカルモデルの設定'));
    await tester.pumpAndSettle();
    expect(find.text('Thinking 表示'), findsNothing);
    expect(find.text('HyperLoad'), findsOneWidget);
    expect(find.text('Context Length'), findsOneWidget);

    // and tapping the open row closes it
    await tester.tap(find.text('ローカルモデルの設定'));
    await tester.pumpAndSettle();
    expect(find.text('HyperLoad'), findsNothing);

    // a switch inside a group changes the settings
    await tester.tap(find.text('ローカルモデルの設定'));
    await tester.pumpAndSettle();
    expect(app.settings.value.hyperLoad, isFalse);
    await app.settings.update((s) => s.copyWith(hyperLoad: true));
    await tester.pump();
    expect(app.settings.value.hyperLoad, isTrue);
  });

  testWidgets('settings page: the sidebar can open a group directly', (tester) async {
    setSize(tester, const Size(1280, 800));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.online);
    await tester.pumpAndSettle();
    expect(find.text('追加プロンプト'), findsOneWidget);
    expect(find.text('top_k'), findsNothing, reason: 'top_k is a device model setting');
    expect(find.text('Context Length'), findsNothing);
  });

  testWidgets('settings page: the KV cache file settings appear once the switch is on', (tester) async {
    setSize(tester, const Size(411, 1200));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.local);
    await tester.pumpAndSettle();
    expect(find.text('KV キャッシュをファイルに保存'), findsOneWidget);
    expect(find.text('保存の上限（合計）'), findsNothing, reason: 'hidden while it is off');

    await app.settings.update((s) => s.copyWith(kvSnapshotEnabled: true));
    await tester.pumpAndSettle();
    expect(find.text('保存の上限（合計）'), findsOneWidget);
    expect(find.text('保存する最小の長さ'), findsOneWidget);
    expect(find.text('この端末（OS）では保存できません'), findsOneWidget, reason: 'there is no device engine in a test');
  });

  testWidgets('settings page: the online group has the model lookup switches, and a 256K length can be typed', (tester) async {
    setSize(tester, const Size(411, 1200));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.online);
    await tester.pumpAndSettle();
    expect(find.text('モデルの上限を自動で調べる'), findsOneWidget);
    expect(find.text('Hugging Face からも調べる'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '2048'), '262144');
    await tester.pump();
    expect(app.settings.value.onlineMaxTokens, 262144, reason: 'the old 32768 ceiling is gone');
  });

  testWidgets('model editor: limits, the maker\'s note and a thinking format can be set and saved', (tester) async {
    setSize(tester, const Size(500, 2600));
    final app = await makeApp(tester);
    const config = ProviderConfig(
      id: 'host',
      label: 'ホスト',
      baseUrl: 'https://host.example/v1',
      models: [ModelConfig(id: 'zai-org/GLM-5.3', name: 'GLM')],
    );
    await app.providers.save(config);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => ModelEditor(app: app, provider: config, model: config.models.single),
              ),
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();

    // the maker's recommendation is shown, and the empty fields show what applies
    expect(find.textContaining('GLM-5 の推奨（公式モデルカード）'), findsOneWidget);
    expect(find.textContaining('GLM-5.3（公式モデルカード）：reasoning_effort'), findsOneWidget);
    expect(find.text('送らない（提供元の既定）'), findsWidgets);
    expect(find.text('clear_thinking（GLM）'), findsNothing, reason: 'no format chosen yet');

    await tester.tap(find.text('おすすめの送り方を入れる'));
    await tester.pumpAndSettle();
    expect(find.textContaining('を選びました'), findsOneWidget);
    expect(find.text('clear_thinking（GLM）'), findsOneWidget);
    expect(find.text('true（過去の思考を捨てる・チャット向け）'), findsWidgets, reason: 'the GLM-5.3 card says to pass true for chat');

    // tools and earlier thinking: the defaults are shown, and a choice is kept
    expect(find.text('自動（提供元がツールに対応していれば function calling）'), findsOneWidget);
    expect(find.text('自動（DeepSeek・GLM で、ツールが function calling のとき返す）'), findsOneWidget);
    await tester.ensureVisible(find.text('自動（提供元がツールに対応していれば function calling）'));
    await tester.tap(find.text('自動（提供元がツールに対応していれば function calling）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('テキスト形式（<tool_call> を本文に書く。Qwen 形式）').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('自動（DeepSeek・GLM で、ツールが function calling のとき返す）'));
    await tester.tap(find.text('自動（DeepSeek・GLM で、ツールが function calling のとき返す）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返さない（答えだけを履歴に残す）').last);
    await tester.pumpAndSettle();

    // the empty context field shows the maker's 1M as its placeholder
    await tester.enterText(find.widgetWithText(TextField, '1048576'), '900000');
    await tester.enterText(find.widgetWithText(TextField, '例: 65536'), '131072');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3)); // the toast's timer

    final saved = app.providers.byId('host')!.models.single;
    expect(saved.thinking.format, ThinkingFormat.chatTemplate, reason: 'a Hugging Face name is served by a vLLM-like host');
    expect(saved.thinking.clearThinking, isTrue);
    expect(saved.contextTokens, 900000);
    expect(saved.maxOutputTokens, 131072);
    expect(saved.toolStyle, ToolStyle.text);
    expect(saved.thinking.replay, ReasoningReplay.never);
  });

  testWidgets('chat: the thinking switch says when an online model does not hear about it', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await app.providers.save(const ProviderConfig(
      id: 'host',
      label: 'ホスト',
      baseUrl: 'https://host.example/v1',
      models: [ModelConfig(id: 'deepseek-v4-flash', name: 'ds')],
    ));
    await app.providers.setActive('host');
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
    expect(app.engine.isCloud, isTrue);

    await tester.tap(find.text('思考'));
    await tester.pump();
    expect(find.textContaining('思考の送り方が未設定'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    // once a format is chosen the model does hear it: the plain message
    await app.providers.save(const ProviderConfig(
      id: 'host',
      label: 'ホスト',
      baseUrl: 'https://host.example/v1',
      models: [ModelConfig(id: 'deepseek-v4-flash', name: 'ds', thinking: ThinkingConfig(format: ThinkingFormat.deepseekApi))],
    ));
    await tester.tap(find.text('思考'));
    await tester.pump();
    expect(find.textContaining('思考の送り方が未設定'), findsNothing);
    expect(find.text('Thinking表示をオン'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('settings page: coding mode asks for both models before it can work', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.coding);
    await tester.pumpAndSettle();
    expect(find.text('設計モデル'), findsOneWidget);
    expect(find.text('開発モデル'), findsOneWidget);
    expect(find.textContaining('両方を選ぶと'), findsNothing, reason: 'no warning while the mode is off');

    await app.settings.update((s) => s.copyWith(codingPlanEnabled: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('両方を選ぶと'), findsOneWidget);
    expect(app.settings.value.coding.isReady, isFalse);

    await app.settings.update((s) => s.copyWith(plannerModel: 'openai|gpt-4o', developerModel: 'local|'));
    await tester.pumpAndSettle();
    expect(app.settings.value.coding.isReady, isTrue);
    expect(find.textContaining('両方を選ぶと'), findsNothing);
    expect(find.textContaining('まだ読み込まれていません'), findsOneWidget, reason: 'the device model is not loaded in a test');
  });

  testWidgets('chat: the 分担 button turns the coding mode on and goes to its settings when it is not ready', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(app.settings.value.codingPlanEnabled, isFalse);
    await tester.tap(find.text('分担'));
    await tester.pumpAndSettle();
    expect(app.settings.value.codingPlanEnabled, isTrue);
    expect(app.page, AppPage.settings, reason: 'it cannot work yet, so the settings open');
    expect(find.text('設計モデル'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // the toast's timer
  });

  testWidgets('settings page: the limits group lists what used to be fixed', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.limits);
    await tester.pumpAndSettle();
    expect(find.text('添付できるファイルの数'), findsOneWidget);
    expect(find.text('検索結果の件数'), findsNothing, reason: 'it moved to the search group');
    expect(find.text('オンラインモデルの応答のタイムアウト'), findsOneWidget);

    // a pill steps to the next value
    expect(app.settings.value.attachMaxFiles, 5);
    await tester.tap(find.text('5').first);
    await tester.pump();
    expect(app.settings.value.attachMaxFiles, 10);
  });

  testWidgets('settings page: the coding model is picked from a list that writes every name out in full', (tester) async {
    setSize(tester, const Size(411, 1200));
    final app = await makeApp(tester);
    await app.providers.save(
      const ProviderConfig(
        id: 'long',
        label: 'Some Very Long Provider Name',
        baseUrl: 'https://example.com/v1',
        models: [ModelConfig(id: 'vendor/an-extremely-long-model-name-that-no-narrow-field-can-show-v2', name: 'vendor/an-extremely-long-model-name-that-no-narrow-field-can-show-v2')],
      ),
    );
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.coding);
    await tester.pumpAndSettle();
    await tester.tap(find.text('未選択').first);
    await tester.pumpAndSettle();

    const full = 'Some Very Long Provider Name · vendor/an-extremely-long-model-name-that-no-narrow-field-can-show-v2';
    expect(find.text(full), findsOneWidget, reason: 'the list shows the whole name, not an ellipsis');
    await tester.tap(find.text(full));
    await tester.pumpAndSettle();
    expect(app.settings.value.plannerModel, contains('long'));
    expect(find.text(full), findsWidgets, reason: 'the field now shows the choice');
  });

  testWidgets('settings page: the search group has the server, the result count and the search APIs', (tester) async {
    setSize(tester, const Size(411, 1200));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.search);
    await tester.pumpAndSettle();
    expect(find.text('SearXNG のアドレス'), findsOneWidget);
    expect(find.text('検索結果の件数'), findsOneWidget);
    expect(find.text('検索 API'), findsOneWidget);
    expect(find.text('検索 API を追加'), findsOneWidget);
    expect(find.text('Thinking 表示'), findsNothing);
  });

  testWidgets('settings page: the sidebar lists the search settings', (tester) async {
    setSize(tester, const Size(1280, 800));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(find.text('検索設定'), findsWidgets);
    expect(find.text('モデル全般設定'), findsWidgets);
    expect(find.text('回答の設定'), findsNothing);
    expect(find.text('開発者設定'), findsNothing);
  });

  testWidgets('a bottom sheet keeps its buttons above the navigation bar and the keyboard', (tester) async {
    late double plain, withBar, withKeyboard;
    Widget probe(MediaQueryData data, void Function(double) out) => MediaQuery(
          data: data,
          child: Builder(builder: (context) {
            out(sheetBottomPadding(context));
            return const SizedBox();
          }),
        );
    await tester.pumpWidget(probe(const MediaQueryData(), (v) => plain = v));
    await tester.pumpWidget(probe(const MediaQueryData(viewPadding: EdgeInsets.only(bottom: 48)), (v) => withBar = v));
    await tester.pumpWidget(probe(const MediaQueryData(viewPadding: EdgeInsets.only(bottom: 48), viewInsets: EdgeInsets.only(bottom: 300)), (v) => withKeyboard = v));
    expect(plain, 16);
    expect(withBar, 64, reason: 'above the three-button bar');
    expect(withKeyboard, 316, reason: 'above the keyboard, which already covers the bar');
  });

  testWidgets('settings page: local and online model settings are kept apart', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.local);
    await tester.pumpAndSettle();
    expect(find.text('top_k'), findsOneWidget);
    expect(find.text('min_p'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '0.6 / 0.7（思考の有無で変わります）'), '0.3');
    await tester.pump();
    expect(app.settings.value.localTemperature, 0.3);
    expect(app.settings.value.onlineTemperature, -1, reason: 'the online setting is untouched');

    final local = app.settings.value.toGeneration(null);
    final online = app.settings.value.toGeneration(null, cloud: true);
    expect(local.temperature, 0.3);
    expect(online.temperature, isNull);
  });

  testWidgets('phone: the hamburger opens a drawer where the history can be searched', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    Map<String, Object?> conversation(String text) => {
          'messages': [
            {'id': 0, 'role': 'user', 'text': text, 'thinking': '', 'question': null, 'finish': null, 'activities': const [], 'agent': null, 'attachments': const [], 'time': 1700000000000},
            {'id': 1, 'role': 'assistant', 'text': '答え：$text', 'thinking': '', 'question': null, 'finish': 'eog', 'activities': const [], 'agent': null, 'attachments': const [], 'time': 1700000005000},
          ],
          'history': [
            {'type': 'user', 'text': text, 'toolCallJson': null},
            {'type': 'assistant', 'text': '答え：$text', 'toolCallJson': null},
          ],
          'nextId': 2,
        };
    await tester.runAsync(() async {
      await app.history.save(null, ConversationSnapshot.fromJson(conversation('りんごの話をして')), generating: false);
      await app.history.save(null, ConversationSnapshot.fromJson(conversation('明日の天気は？')), generating: false);
      await app.refreshConversations();
    });
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(find.byType(Drawer), findsNothing);
    await tester.tap(find.byTooltip('メニュー'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
    expect(find.text('りんごの話をして'), findsOneWidget);
    expect(find.text('明日の天気は？'), findsOneWidget);

    final search = find.descendant(of: find.byType(Drawer), matching: find.byType(TextField));
    await tester.enterText(search, '天気');
    await tester.pump();
    expect(find.text('りんごの話をして'), findsNothing);
    expect(find.text('明日の天気は？'), findsOneWidget);

    // a word that is only in an answer finds the conversation too, with the matching line
    await tester.enterText(search, 'りんご');
    await tester.pump();
    // the title, and the matching line under it with the match highlighted
    expect(find.text('りんごの話をして'), findsWidgets);
    expect(find.text('明日の天気は？'), findsNothing);
    await tester.enterText(search, '答え');
    await tester.pump();
    expect(find.textContaining('答え：', findRichText: true), findsWidgets, reason: 'a word only in an answer still finds it');
    expect(find.text('明日の天気は？'), findsOneWidget, reason: 'its title, listed because its answer matches');

    await tester.enterText(search, 'ぶどう');
    await tester.pump();
    expect(find.textContaining('一致する会話はありません'), findsOneWidget);

    await tester.enterText(search, 'りんご');
    await tester.pump();
    await tester.tap(find.text('りんごの話をして').first);
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing, reason: 'opening a conversation closes the drawer');
    expect(app.chat.state.messages.first.text, 'りんごの話をして');
  });

  testWidgets('desktop: the hamburger hides and shows the sidebar', (tester) async {
    setSize(tester, const Size(1280, 800));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(find.text('ダークモード'), findsOneWidget);
    await tester.tap(find.byTooltip('サイドバーを開閉'));
    await tester.pump();
    expect(find.text('ダークモード'), findsNothing);
    await tester.tap(find.byTooltip('サイドバーを開閉'));
    await tester.pump();
    expect(find.text('ダークモード'), findsOneWidget);
  });
}
