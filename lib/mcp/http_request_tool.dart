import 'package:http/http.dart' as http;

import '../core/protocol.dart';
import '../core/secret_book.dart';
import '../core/tool_runtime.dart';

/// What `http_request` reads from the settings, when it is called.
class HttpRequestSettings {
  const HttpRequestSettings({
    this.enabled = true,
    this.confirm = 'secretOrWrite',
    this.maxResponseChars = 20000,
    this.timeoutSeconds = 30,
    this.allowInsecure = false,
  });

  final bool enabled;

  /// `secretOrWrite`, `all` or `never`.
  final String confirm;
  final int maxResponseChars;
  final int timeoutSeconds;
  final bool allowInsecure;
}

/// The tool `http_request` (docs 15.13, path A): a model asks the app to call an address, writing
/// `{{secret:ID}}` where a key or a token goes; the app puts the value in, only for the hosts that secret is
/// bound to, sends the request itself (not through proot), and hands back the answer with every value taken out.
///
/// THIS IS A PLACE HOLDER that the work of path A fills in; [McpTools] already calls it.
class HttpRequestTool {
  HttpRequestTool({required this.book, this.settings = const HttpRequestSettings(), this.client});

  final SecretBook book;
  final HttpRequestSettings settings;
  /// The client the request goes through (a test gives its own); null: a new one.
  final http.Client? client;

  /// The definition the model is offered, with the ids of the secrets it may name written into the
  /// description (the model cannot look them up). Null when the tool is off.
  ToolDefinition? definition() => null;

  /// Whether the user approves this call first (see [HttpRequestSettings.confirm]).
  bool needsApproval(Map<String, Object?> arguments) => false;

  Future<ToolOutcome> run(Map<String, Object?> arguments) async => const ToolOutcome(
        'http_request is not built yet.',
        ToolActivity('HTTP', 'まだ作っていません', failed: true),
      );
}
