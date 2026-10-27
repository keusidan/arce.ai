import 'package:arce_ai/ui/chat_widgets.dart';
import 'package:arce_ai/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _reply = '## 結論から\n\n'
    'Fireworks.ai には **「spot モデル」という製品カテゴリは存在しません**。*斜体*と~~取り消し~~と`code`。\n\n'
    '| 形態 | 課金 | spot的か |\n|---|---|:-:|\n| Serverless | トークン課金 | ✗ |\n| **Preemptible** | 遊休の GPU を借りる | ✓ |\n\n'
    '- **容量モデル**：アイドル状態の GPU\n  - 入れ子の項目\n- 作成方法\n\n'
    '1. 一つ目\n2. 二つ目\n\n'
    '> 引用された文\n\n---\n\n'
    '詳しくは [公式](https://docs.fireworks.ai/guides/ondemand-deployments) と https://fireworks.ai/pricing を見てください。\n\n'
    '```bash\nfirectl deployment create --preemptible\n```';

Future<void> pumpReply(WidgetTester tester, String text, {double width = 411}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: RichReply(text: text))),
  ));
}

/// Every span of the rich texts on screen that has a recognizer, with its text.
List<TextSpan> tappableSpans(WidgetTester tester) {
  final found = <TextSpan>[];
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      if (span.recognizer is TapGestureRecognizer) found.add(span);
      span.children?.forEach(walk);
    }
  }

  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(rich.text);
  }
  return found;
}

void main() {
  testWidgets('a Markdown reply shows its heading, table, lists, quote and code, without overflow', (tester) async {
    await pumpReply(tester, _reply);
    expect(tester.takeException(), isNull);

    bool has(String text) => find.textContaining(text, findRichText: true).evaluate().isNotEmpty;
    expect(has('結論から'), isTrue);
    expect(has('## 結論から'), isFalse, reason: 'the # marks are not shown');
    expect(has('**'), isFalse, reason: 'the bold marks are not shown');
    expect(has('Preemptible'), isTrue, reason: 'a table cell');
    expect(has('遊休の GPU を借りる'), isTrue);
    expect(find.byType(Table), findsOneWidget);
    expect(has('入れ子の項目'), isTrue);
    expect(has('•'), isTrue, reason: 'a bullet');
    expect(has('2.'), isTrue, reason: 'a number');
    expect(has('引用された文'), isTrue);
    expect(find.byType(CodeCard), findsOneWidget);
  });

  testWidgets('links (written as [text](address) or bare) can be tapped; other text cannot', (tester) async {
    await pumpReply(tester, _reply);
    final links = tappableSpans(tester).map((s) => s.text).toList();
    expect(links, ['公式', 'https://fireworks.ai/pricing']);
  });

  testWidgets('a wide table scrolls sideways instead of overflowing, on a narrow screen', (tester) async {
    final header = [for (var i = 0; i < 8; i++) '列その$i'].join(' | ');
    final separator = [for (var i = 0; i < 8; i++) '---'].join('|');
    final row = [for (var i = 0; i < 8; i++) 'とても長いセルの内容 $i です'].join(' | ');
    await pumpReply(tester, '| $header |\n|$separator|\n| $row |', width: 320);
    expect(tester.takeException(), isNull);
    expect(find.byType(Table), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal), findsOneWidget);
  });

  testWidgets('half-written Markdown shows as typed and does not throw while it streams', (tester) async {
    for (final partial in ['**太', '| a | b |\n|--', '```dart\nvoid main() {', '[公式](https://exa', '- ', '> ', '## ']) {
      await pumpReply(tester, partial);
      expect(tester.takeException(), isNull, reason: partial);
    }
  });

  testWidgets('a long quote and a long code block have copy buttons; a short quote does not', (tester) async {
    final longCode = [for (var i = 0; i < 20; i++) 'line $i'].join('\n');
    await pumpReply(tester, '> 短い引用\n\n> 一行目の指示です。\n> 二行目の指示です。\n> 三行目の指示です。\n\n```text\n$longCode\n```\n\n```text\nshort\n```');
    expect(tester.takeException(), isNull);
    // the long quote: one; the long code: two (header and end); the short code: one (header)
    expect(find.text('コピー'), findsNWidgets(1 + 2 + 1));
  });

  testWidgets('the copy button of a quote puts the text without > on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpReply(tester, '> 一行目の指示です。\n> 二行目の指示です。\n> 三行目の指示です。');
    await tester.tap(find.text('コピー'));
    await tester.pump();
    expect(copied, '一行目の指示です。\n二行目の指示です。\n三行目の指示です。');
  });
}
