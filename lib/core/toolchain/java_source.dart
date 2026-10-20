/// What the on-device Java tools need to know about one source file from a code block:
/// its file name, the class with `main`, and the Activity for an APK. Regex-based on purpose:
/// it only has to be right for the single-file programs a chat produces; the compiler reports
/// anything else.
///
/// Ported from the Kotlin version (`core/src/main/kotlin/ai/arce/core/toolchain/JavaSource.kt`).
class JavaSource {
  const JavaSource({
    required this.code,
    this.packageName,
    required this.primaryClass,
    this.mainClass,
    this.activityClass,
  });

  final String code;
  final String? packageName;

  /// Public top-level class, which fixes the file name; else the first class.
  final String primaryClass;

  /// Fully qualified class with `public static void main(String[])`, if any.
  final String? mainClass;

  /// Fully qualified class extending android.app.Activity (or a known subclass), if any.
  final String? activityClass;

  String get fileName => '$primaryClass.java';

  /// The same source with a package added when it had none (an APK's classes need one).
  JavaSource withPackage(String fallback) =>
      packageName != null ? this : JavaSource.parse('package $fallback;\n$code');

  static const javaLevel = '1.8';

  static final _comments = RegExp(r'/\*[\s\S]*?\*/|//[^\n]*');
  static final _strings = RegExp(r'"(?:\\.|[^"\\\n])*"');
  static final _pkg = RegExp(r'^\s*package\s+([\w.]+)\s*;', multiLine: true);
  static final _publicClass = RegExp(r'\bpublic\s+(?:final\s+|abstract\s+)*class\s+(\w+)');
  static final _anyClass = RegExp(r'\bclass\s+(\w+)');
  static final _mainMethod = RegExp(r'\bpublic\s+static\s+void\s+main\s*\(\s*(?:final\s+)?String\s*'
      r'(?:\[\s*\]\s*\w+|\.\.\.\s*\w+|\w+\s*\[\s*\])\s*\)');
  static final _activity =
      RegExp(r'\bclass\s+(\w+)\s+extends\s+(?:android\.app\.)?(?:Activity|ListActivity)\b');

  static JavaSource parse(String code) {
    // Search a copy without comments and string contents so they cannot fake a match.
    final bare = code.replaceAll(_comments, ' ').replaceAll(_strings, '""');
    final packageName = _pkg.firstMatch(bare)?.group(1);
    final classes = [
      for (final m in _anyClass.allMatches(bare)) (name: m.group(1)!, start: m.start),
    ];
    if (classes.isEmpty) throw ArgumentError('クラス宣言が見つかりません');
    final primary = _publicClass.firstMatch(bare)?.group(1) ?? classes.first.name;

    String qualified(String name) => packageName == null ? name : '$packageName.$name';

    // main belongs to the nearest class declared before it
    String? main;
    final mainMatch = _mainMethod.firstMatch(bare);
    if (mainMatch != null) {
      for (final c in classes) {
        if (c.start >= mainMatch.start) break;
        main = c.name;
      }
    }

    final activityName = _activity.firstMatch(bare)?.group(1);
    return JavaSource(
      code: code,
      packageName: packageName,
      primaryClass: primary,
      mainClass: main == null ? null : qualified(main),
      activityClass: activityName == null ? null : qualified(activityName),
    );
  }
}
