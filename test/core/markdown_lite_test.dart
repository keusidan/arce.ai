import 'package:arce_ai/core/markdown_lite.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bold spans', () {
    expect(MarkdownLite.spans('これは**重要**です'), [
      const Span('これは', bold: false),
      const Span('重要', bold: true),
      const Span('です', bold: false),
    ]);
  });

  test('an unmatched marker stays literal while streaming', () {
    expect(MarkdownLite.spans('a **b'), [const Span('a **b', bold: false)]);
  });

  test('text and a closed code block', () {
    final blocks = MarkdownLite.parse('例:\n```html\n<p>hi</p>\n```\n以上');
    expect(blocks, hasLength(3));
    expect((blocks[0] as Paragraph).spans, [const Span('例:', bold: false)]);
    final code = blocks[1] as CodeBlock;
    expect((code.language, code.code, code.closed), ('html', '<p>hi</p>', true));
    expect((blocks[2] as Paragraph).spans, [const Span('以上', bold: false)]);
  });

  test('a code block still being streamed is open', () {
    final open = MarkdownLite.parse('```kotlin\nfun main() {').single as CodeBlock;
    expect((open.language, open.code, open.closed), ('kotlin', 'fun main() {', false));
    final header = MarkdownLite.parse('```py').single as CodeBlock;
    expect((header.language, header.code, header.closed), ('py', '', false));
  });
}
