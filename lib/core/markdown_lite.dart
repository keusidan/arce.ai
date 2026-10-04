class Span {
  const Span(this.text, {required this.bold});
  final String text;
  final bool bold;

  @override
  bool operator ==(Object other) => other is Span && other.text == text && other.bold == bold;

  @override
  int get hashCode => Object.hash(text, bold);

  @override
  String toString() => 'Span($text, bold: $bold)';
}

sealed class Block {
  const Block();
}

class Paragraph extends Block {
  const Paragraph(this.spans);
  final List<Span> spans;
}

class CodeBlock extends Block {
  const CodeBlock(this.language, this.code, {required this.closed});
  final String language;
  final String code;

  /// False while the fence is still being streamed; an Artifact can wait for it.
  final bool closed;
}

/// The two notations the system prompt asks for: `**bold**` and fenced code blocks.
/// Tolerates half-streamed input: an unclosed fence becomes an open code block and an
/// unmatched `**` is shown as-is.
abstract final class MarkdownLite {
  static const _fence = '```';

  static List<Block> parse(String text) {
    final blocks = <Block>[];
    var rest = text;
    while (rest.isNotEmpty) {
      final open = rest.indexOf(_fence);
      if (open < 0) {
        _addParagraph(rest, blocks);
        break;
      }
      _addParagraph(rest.substring(0, open), blocks);
      final afterFence = rest.substring(open + _fence.length);
      final headerEnd = afterFence.indexOf('\n');
      if (headerEnd < 0) {
        // only "```lang" so far
        blocks.add(CodeBlock(afterFence.trim(), '', closed: false));
        break;
      }
      final language = afterFence.substring(0, headerEnd).trim();
      final body = afterFence.substring(headerEnd + 1);
      final close = body.indexOf(_fence);
      if (close < 0) {
        blocks.add(CodeBlock(language, body, closed: false));
        break;
      }
      var code = body.substring(0, close);
      if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
      blocks.add(CodeBlock(language, code, closed: true));
      rest = body.substring(close + _fence.length);
      if (rest.startsWith('\n')) rest = rest.substring(1);
    }
    return blocks;
  }

  static List<Span> spans(String text) {
    final spans = <Span>[];
    var i = 0;
    var bold = false;
    final current = StringBuffer();
    while (i < text.length) {
      if (text.startsWith('**', i) && (bold || text.indexOf('**', i + 2) >= 0)) {
        if (current.isNotEmpty) spans.add(Span(current.toString(), bold: bold));
        current.clear();
        bold = !bold;
        i += 2;
      } else {
        current.write(text[i]);
        i++;
      }
    }
    if (current.isNotEmpty) spans.add(Span(current.toString(), bold: bold));
    return spans;
  }

  static void _addParagraph(String text, List<Block> blocks) {
    final trimmed = _trimNewlines(text);
    if (trimmed.isNotEmpty) blocks.add(Paragraph(spans(trimmed)));
  }

  static String _trimNewlines(String s) {
    var start = 0;
    var end = s.length;
    while (start < end && s[start] == '\n') {
      start++;
    }
    while (end > start && s[end - 1] == '\n') {
      end--;
    }
    return s.substring(start, end);
  }
}
