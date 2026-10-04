import 'package:arce_ai/core/syntax_highlight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps every character while colouring Dart keywords, strings and comments', () {
    const source = 'final answer = "42"; // comment';
    final spans = SyntaxHighlighter.highlight(source, 'dart');

    expect(spans.map((s) => s.text).join(), source);
    expect(spans.where((s) => s.token == SyntaxToken.keyword).map((s) => s.text), contains('final'));
    expect(spans.where((s) => s.token == SyntaxToken.string).map((s) => s.text), contains('"42"'));
    expect(spans.where((s) => s.token == SyntaxToken.comment).map((s) => s.text), contains('// comment'));
  });

  test('recognises aliases and incomplete strings without dropping streamed text', () {
    const source = 'def hello(name):\n  return "Hello, \$name';
    final spans = SyntaxHighlighter.highlight(source, 'py');

    expect(spans.map((s) => s.text).join(), source);
    expect(spans.firstWhere((s) => s.text == 'def').token, SyntaxToken.keyword);
    expect(spans.last.token, SyntaxToken.string);
  });

  test('marks markup fences as tags', () {
    final spans = SyntaxHighlighter.highlight('<h1 class="title">Hello</h1>', 'html');

    expect(spans.where((s) => s.token == SyntaxToken.tag).map((s) => s.text), ['<h1 class="title">', '</h1>']);
  });
}
