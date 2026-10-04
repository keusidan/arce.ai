/// Lightweight, dependency-free syntax highlighting for the code fences shown in chat.
///
/// It intentionally recognises tokens rather than trying to parse a whole program. That keeps
/// highlighting responsive while a model is still streaming an incomplete code block and works
/// equally on Android, Windows and Linux without bundling a WebView or a native grammar library.
enum SyntaxToken { plain, keyword, string, comment, number, type, tag, attribute }

class SyntaxSpan {
  const SyntaxSpan(this.text, this.token);

  final String text;
  final SyntaxToken token;

  @override
  bool operator ==(Object other) => other is SyntaxSpan && other.text == text && other.token == token;

  @override
  int get hashCode => Object.hash(text, token);
}

abstract final class SyntaxHighlighter {
  static const _aliases = {
    'js': 'javascript',
    'jsx': 'javascript',
    'ts': 'typescript',
    'tsx': 'typescript',
    'py': 'python',
    'c++': 'cpp',
    'c#': 'csharp',
    'sh': 'bash',
    'shell': 'bash',
    'yml': 'yaml',
    'htm': 'html',
  };

  static const _keywords = {
    'dart': {
      'abstract', 'as', 'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue',
      'default', 'do', 'else', 'enum', 'extends', 'false', 'final', 'finally', 'for', 'if',
      'implements', 'import', 'in', 'interface', 'is', 'late', 'mixin', 'new', 'null', 'on',
      'operator', 'part', 'rethrow', 'return', 'sealed', 'static', 'super', 'switch', 'this',
      'throw', 'true', 'try', 'typedef', 'var', 'void', 'while', 'with', 'yield',
    },
    'kotlin': {
      'as', 'break', 'class', 'continue', 'data', 'do', 'else', 'false', 'for', 'fun', 'if',
      'in', 'interface', 'is', 'null', 'object', 'package', 'private', 'protected', 'public',
      'return', 'sealed', 'suspend', 'this', 'throw', 'true', 'try', 'typealias', 'val', 'var',
      'when', 'while',
    },
    'java': {
      'abstract', 'boolean', 'break', 'byte', 'case', 'catch', 'char', 'class', 'continue',
      'default', 'do', 'double', 'else', 'enum', 'extends', 'false', 'final', 'finally', 'float',
      'for', 'if', 'implements', 'import', 'instanceof', 'int', 'interface', 'long', 'new',
      'null', 'package', 'private', 'protected', 'public', 'return', 'short', 'static', 'super',
      'switch', 'this', 'throw', 'true', 'try', 'void', 'while',
    },
    'python': {
      'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue', 'def', 'del', 'elif',
      'else', 'except', 'False', 'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is',
      'lambda', 'None', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'True', 'try', 'while',
      'with', 'yield',
    },
    'javascript': {
      'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'delete',
      'do', 'else', 'export', 'extends', 'false', 'finally', 'for', 'from', 'function', 'if',
      'import', 'in', 'instanceof', 'let', 'new', 'null', 'of', 'return', 'static', 'super',
      'switch', 'this', 'throw', 'true', 'try', 'typeof', 'undefined', 'var', 'void', 'while',
      'with', 'yield',
    },
    'typescript': {
      'abstract', 'any', 'as', 'async', 'await', 'boolean', 'break', 'case', 'catch', 'class',
      'const', 'continue', 'declare', 'default', 'else', 'enum', 'export', 'extends', 'false',
      'for', 'function', 'if', 'implements', 'import', 'interface', 'keyof', 'let', 'new', 'never',
      'null', 'number', 'private', 'public', 'readonly', 'return', 'static', 'string', 'this',
      'throw', 'true', 'try', 'type', 'undefined', 'unknown', 'var', 'void', 'while',
    },
    'c': {
      'auto', 'break', 'case', 'char', 'const', 'continue', 'default', 'do', 'double', 'else',
      'enum', 'extern', 'float', 'for', 'goto', 'if', 'int', 'long', 'return', 'short', 'signed',
      'sizeof', 'static', 'struct', 'switch', 'typedef', 'union', 'unsigned', 'void', 'volatile', 'while',
    },
    'cpp': {
      'alignas', 'auto', 'bool', 'break', 'case', 'catch', 'char', 'class', 'const', 'constexpr',
      'continue', 'default', 'delete', 'do', 'double', 'else', 'enum', 'explicit', 'false', 'float',
      'for', 'friend', 'if', 'inline', 'int', 'long', 'namespace', 'new', 'nullptr', 'operator',
      'private', 'protected', 'public', 'return', 'short', 'signed', 'sizeof', 'static', 'struct',
      'switch', 'template', 'this', 'throw', 'true', 'try', 'typename', 'union', 'unsigned', 'using',
      'virtual', 'void', 'while',
    },
    'csharp': {
      'async', 'await', 'bool', 'break', 'case', 'catch', 'class', 'const', 'continue', 'decimal',
      'default', 'delegate', 'do', 'double', 'else', 'enum', 'event', 'explicit', 'false', 'finally',
      'float', 'for', 'foreach', 'if', 'in', 'int', 'interface', 'internal', 'is', 'lock', 'long',
      'namespace', 'new', 'null', 'object', 'private', 'protected', 'public', 'readonly', 'return',
      'sealed', 'static', 'string', 'struct', 'switch', 'this', 'throw', 'true', 'try', 'using',
      'var', 'virtual', 'void', 'while',
    },
    'json': {'true', 'false', 'null'},
    'yaml': {'true', 'false', 'null', 'yes', 'no'},
    'bash': {'case', 'do', 'done', 'echo', 'elif', 'else', 'esac', 'export', 'fi', 'for', 'function', 'if', 'in', 'then', 'while'},
    'sql': {'select', 'from', 'where', 'join', 'left', 'right', 'inner', 'outer', 'on', 'insert', 'into', 'update', 'delete', 'create', 'table', 'alter', 'drop', 'as', 'and', 'or', 'not', 'null', 'order', 'by', 'group', 'limit'},
  };

  static List<SyntaxSpan> highlight(String source, String language) {
    if (source.isEmpty) return const [];
    final lang = _aliases[language.trim().toLowerCase()] ?? language.trim().toLowerCase();
    final html = lang == 'html' || lang == 'xml' || lang == 'svg';
    final keywordSet = _keywords[lang] ?? const <String>{};
    final hashComment = lang == 'python' || lang == 'bash' || lang == 'yaml';
    final slashComment = !hashComment && lang != 'json' && !html;
    final out = <SyntaxSpan>[];

    void add(String text, SyntaxToken token) {
      if (text.isEmpty) return;
      if (out.isNotEmpty && out.last.token == token) {
        final previous = out.removeLast();
        out.add(SyntaxSpan(previous.text + text, token));
      } else {
        out.add(SyntaxSpan(text, token));
      }
    }

    var i = 0;
    while (i < source.length) {
      final current = source[i];
      if (html && current == '<') {
        final end = source.indexOf('>', i + 1);
        if (end >= 0) {
          final markup = source.substring(i, end + 1);
          add(markup, SyntaxToken.tag);
          i = end + 1;
          continue;
        }
      }
      if (hashComment && current == '#') {
        final end = _lineEnd(source, i);
        add(source.substring(i, end), SyntaxToken.comment);
        i = end;
        continue;
      }
      if (slashComment && source.startsWith('//', i)) {
        final end = _lineEnd(source, i);
        add(source.substring(i, end), SyntaxToken.comment);
        i = end;
        continue;
      }
      if (slashComment && source.startsWith('/*', i)) {
        final close = source.indexOf('*/', i + 2);
        final end = close < 0 ? source.length : close + 2;
        add(source.substring(i, end), SyntaxToken.comment);
        i = end;
        continue;
      }
      if (current == '\'' || current == '"' || (lang == 'javascript' && current == '`')) {
        final end = _quotedEnd(source, i, current);
        add(source.substring(i, end), SyntaxToken.string);
        i = end;
        continue;
      }
      if (_isWordStart(current)) {
        var end = i + 1;
        while (end < source.length && _isWordPart(source[end])) {
          end++;
        }
        final word = source.substring(i, end);
        final isKeyword = keywordSet.contains(word) || keywordSet.contains(word.toLowerCase());
        final isType = word.length > 1 && word[0].toUpperCase() == word[0] && lang != 'json';
        add(word, isKeyword ? SyntaxToken.keyword : (isType ? SyntaxToken.type : SyntaxToken.plain));
        i = end;
        continue;
      }
      if (_isDigit(current) && (i == 0 || !_isWordPart(source[i - 1]))) {
        var end = i + 1;
        while (end < source.length && RegExp(r'[0-9a-fA-F_xX.]').hasMatch(source[end])) {
          end++;
        }
        add(source.substring(i, end), SyntaxToken.number);
        i = end;
        continue;
      }
      add(current, SyntaxToken.plain);
      i++;
    }
    return out;
  }

  static int _lineEnd(String text, int from) {
    final end = text.indexOf('\n', from);
    return end < 0 ? text.length : end;
  }

  static int _quotedEnd(String text, int start, String quote) {
    var i = start + 1;
    while (i < text.length) {
      if (text[i] == '\\') {
        i += 2;
      } else if (text[i] == quote) {
        return i + 1;
      } else {
        i++;
      }
    }
    return text.length;
  }

  static bool _isWordStart(String value) => RegExp(r'[A-Za-z_\$]').hasMatch(value);
  static bool _isWordPart(String value) => RegExp(r'[A-Za-z0-9_\$]').hasMatch(value);
  static bool _isDigit(String value) => RegExp(r'[0-9]').hasMatch(value);
}
