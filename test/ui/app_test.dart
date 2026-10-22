import 'dart:io';

import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/releases.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:arce_ai/services/settings.dart';
import 'package:arce_ai/services/update_service.dart';
import 'package:arce_ai/app.dart';
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

    await tester.tap(find.text('基本設定').first);
    await tester.pumpAndSettle();
    expect(find.text('Thinking 表示'), findsOneWidget);
    expect(find.text('HyperLoad'), findsNothing, reason: 'the local model group is not mixed in');
    expect(find.text('Context Length'), findsNothing);
    expect(find.text('口調'), findsNothing, reason: 'nor is the answer group');
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
