/// Result of running generated code in a sandbox process.
///
/// Ported from the Kotlin version (`app/src/main/kotlin/ai/arce/app/sandbox/SandboxService.kt`).
class SandboxResult {
  const SandboxResult(this.ok, this.output, {this.timedOut = false});

  final bool ok;

  /// What the program printed, or why it failed.
  final String output;

  /// True when the time limit stopped the program (its process is killed afterwards).
  final bool timedOut;

  static const maxOutput = 64 * 1024;

  Map<String, Object?> toJson() => {'ok': ok, 'output': output, 'timedOut': timedOut};

  factory SandboxResult.fromJson(Map<String, Object?> json) => SandboxResult(
        json['ok'] as bool? ?? false,
        json['output'] as String? ?? '',
        timedOut: json['timedOut'] as bool? ?? false,
      );

  @override
  String toString() => 'SandboxResult(ok: $ok, timedOut: $timedOut, ' 'output: ${output.length} chars)';
}

/// Runs generated code outside the UI process.
///
/// Android implements this over the two sandbox services (`:python` and `:java`); every other
/// platform gets [NoSandbox], because there is no runtime to run the code with.
abstract interface class SandboxRunner {
  /// Runs Python in the `:python` process. Chaquopy needs the app's own files directory, so this
  /// process runs with the app's permissions; see the consent text shown before the first run.
  Future<SandboxResult> runPython(String code, {Duration timeout});

  /// Runs an already-compiled dex in the isolated `:java` process. Compiling Java into a dex is
  /// the caller's job (ECJ and D8, on the device).
  Future<SandboxResult> runDex(List<int> dex, String mainClass, {Duration timeout});
}

/// The same limit the Kotlin version used; the service enforces it and then kills its process.
const sandboxDefaultTimeout = Duration(seconds: 20);

/// What every platform without a runtime answers. The tool result says so rather than failing.
class NoSandbox implements SandboxRunner {
  const NoSandbox();

  static const _message = 'この端末ではコードを実行できません（実行はAndroid版のみ）。';

  @override
  Future<SandboxResult> runPython(String code, {Duration timeout = sandboxDefaultTimeout}) async =>
      const SandboxResult(false, _message);

  @override
  Future<SandboxResult> runDex(List<int> dex, String mainClass,
          {Duration timeout = sandboxDefaultTimeout}) async =>
      const SandboxResult(false, _message);
}
