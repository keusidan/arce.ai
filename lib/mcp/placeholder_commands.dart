import '../core/secret_book.dart';

/// A command (or a line typed into a session) after its placeholders were dealt with.
class PreparedCommand {
  const PreparedCommand({required this.command, this.env = const {}, this.ids = const [], this.problem});

  /// What is run: each `{{secret:ID}}` replaced by a reference to an environment variable (never the value).
  final String command;

  /// Environment variable name -> value, for the process of this one command.
  final Map<String, String> env;

  /// The ids of the secrets that were used, for the approval card and the log.
  final List<String> ids;

  /// Why the command may not run (an unknown or unusable secret, an address the secret may not go to), or null.
  final String? problem;
}

/// Path B of docs 15.13: `{{secret:ID}}` in a command that runs in proot.
///
/// THIS IS A PLACE HOLDER that the work of path B fills in; [McpTools] already calls it.
abstract final class PlaceholderCommands {
  /// Deals with the placeholders in [command]. Nothing in it: the same command, no secret.
  static PreparedCommand prepare(String command, SecretBook book, {bool allowInsecure = false}) => PreparedCommand(command: command);
}
