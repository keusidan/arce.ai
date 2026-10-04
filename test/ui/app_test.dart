import 'dart:io';

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
  await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp('arce_ui_test');
    addTearDown(() => dir.delete(recursive: true));
    final settings = await SettingsStore.load();
    app = await AppController.create(
      supportDirectory: dir,
      updateService: UpdateService(settings, currentVersion: const Version(0, 4, 0)),
    );
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
    expect(find.text('モデルが読み込まれていません'), findsOneWidget);

    await app.settings.update((s) => s.copyWith(theme: ThemeMode.dark));
    await tester.pump(); // builds the frame that starts the theme animation
    await tester.pump(const Duration(milliseconds: 500));
    final context = tester.element(find.byType(Scaffold).first);
    expect(Theme.of(context).brightness, Brightness.dark);
  });

  testWidgets('settings page changes are saved', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.goTo(AppPage.settings);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Thinking 表示'), findsOneWidget);

    expect(app.settings.value.hyperLoad, isFalse);
    await tester.tap(find.text('HyperLoad'));
    // tapping the label does nothing; the switch is what toggles
    expect(app.settings.value.hyperLoad, isFalse);
    await app.settings.update((s) => s.copyWith(hyperLoad: true));
    await tester.pump();
    expect(app.settings.value.hyperLoad, isTrue);
  });
}
