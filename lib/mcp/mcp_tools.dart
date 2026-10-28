import 'dart:convert';

import '../ai/token_budget.dart';
import '../core/protocol.dart';
import '../core/tool_runtime.dart';
import '../services/ci_client.dart';
import '../services/linux_env.dart';
import 'mcp_client.dart';
import 'mcp_server.dart';

/// One configured server together with the client that talks to it.
class McpServerClient {
  const McpServerClient(this.config, this.client);
  final McpServerConfig config;
  final McpClient client;
}

/// The tools of every MCP server the user configured, as the chat sees them.
///
/// A server may publish a name the app already has (`search`, `get_time` ...), so every tool is
/// prefixed with its server: `mcp_<serverId>__<tool>`. The prefix is stripped again before the
/// call goes out and routed to that server only.
///
/// `tools/list` is cached per server for the life of the [cache] map, so a chat turn does not ask
/// every server again. A server that fails is left out for this turn and tried again next time.
///
/// The app's own tools (`run_command`, `ci_status`) are offered from here too, because this is
/// where the chat already looks for calls it cannot run itself: `ToolCallParser` turns every tool
/// the turn allows into an [McpCall], and this class runs those on the device instead of sending
/// them to a server. When the shell settings arrive (docs 19.5, step 3) the runner moves to
/// `AppController`.
class McpTools {
  McpTools(this._servers, {Map<String, List<McpTool>>? cache, this.ciToken = ''})
    : _cache = cache ?? {};

  final List<McpServerClient> _servers;
  final Map<String, List<McpTool>> _cache;

  /// The token `ci_status` reads GitHub Actions with: the one typed for the GitHub server, which is
  /// read only here. Empty means the public API, which answers for a public repository.
  final String ciToken;

  static const prefix = 'mcp_';
  static const separator = '__';

  static String toolName(String serverId, String tool) =>
      '$prefix$serverId$separator$tool';

  /// Splits `mcp_<id>__<tool>`; null when [name] is not an MCP tool of this shape.
  static (String, String)? parseName(String name) {
    if (!name.startsWith(prefix)) return null;
    final rest = name.substring(prefix.length);
    final at = rest.indexOf(separator);
    if (at <= 0 || at + separator.length >= rest.length) return null;
    return (rest.substring(0, at), rest.substring(at + separator.length));
  }

  static String _cacheKey(McpServerConfig config) =>
      '${config.id}|${config.url}';

  /// The verbs of tools that change something outside the device. Those are shown to the user as
  /// one card and run only when they approve: a chat message must not push code to a repository
  /// without a second look.
  static bool needsApproval(String name) => ToolApproval.needsApproval(name);

  /// Whether [name] needs an approval card, following the server's own setting as well.
  bool approvalRequired(String name) {
    // ci_status only reads GitHub: nothing to approve
    if (name == Protocol.ciStatusName) return false;
    // a command in the app's Linux environment is shown every time: it can do anything the app
    // itself can (docs 15.4). This becomes the setting `shellConfirm`.
    if (name == Protocol.runCommandName) return LinuxEnvironment.supported;
    final parsed = parseName(name);
    if (parsed == null) return false;
    final server = _serverById(parsed.$1);
    if (server == null) return false;
    return server.config.approveWrites && needsApproval(name);
  }

  McpServerClient? _serverById(String id) {
    for (final server in _servers) {
      if (server.config.id == id) return server;
    }
    return null;
  }

  Future<List<McpTool>?> _toolsOf(McpServerClient server) async {
    final key = _cacheKey(server.config);
    final cached = _cache[key];
    if (cached != null) return cached;
    try {
      final tools = await server.client.listTools();
      _cache[key] = tools;
      return tools;
    } on Object {
      // an unreachable server yields no tools; the chat still works this turn
      _cache.remove(key);
      return null;
    }
  }

  /// The tools of all reachable servers in the app's own form.
  Future<List<ToolDefinition>> definitions() async {
    final out = <ToolDefinition>[
      if (LinuxEnvironment.supported) Protocol.runCommand,
      Protocol.ciStatus,
    ];
    for (final server in _servers) {
      final tools = await _toolsOf(server);
      if (tools == null) continue;
      for (final tool in tools) {
        out.add(
          ToolDefinition(
            name: toolName(server.config.id, tool.name),
            description: tool.description.trim().isEmpty
                ? 'MCP tool ${tool.name} (${server.config.name})'
                : '${tool.description.trim()}\n(MCP tool: ${tool.name} / server: ${server.config.name})',
            parameters: tool.parameters,
          ),
        );
      }
    }
    return out;
  }

  /// Human-readable list for the settings screen, for one server.
  Future<String> describe(String id) async {
    final server = _serverById(id);
    if (server == null) return 'サーバーが設定されていません';
    _cache.remove(_cacheKey(server.config));
    final tools = await _toolsOf(server);
    if (tools == null) return '接続できません';
    if (tools.isEmpty) return 'ツールが1つも公開されていません';
    return '${tools.length} 個のツール（毎回の送信に約 ${TokenBudget.estimate(_definitionText(tools))} トークン）: ${tools.map((t) => t.name).join(', ')}';
  }

  /// What the tools of one server add to every request, as text: the tokens are counted from it.
  static String _definitionText(List<McpTool> tools) => [
        for (final tool in tools) '${tool.name} ${tool.description} ${jsonEncode(tool.parameters)}',
      ].join('\n');

  /// How many tokens the tools of server [id] add to every request; null when it cannot be reached.
  Future<int?> overheadTokens(String id) async {
    final server = _serverById(id);
    if (server == null) return null;
    final tools = await _toolsOf(server);
    return tools == null ? null : TokenBudget.estimate(_definitionText(tools));
  }

  Future<ToolOutcome> run(McpCall call) async {
    if (call.name == Protocol.ciStatusName) return _runCiStatus(call.arguments);
    if (call.name == Protocol.runCommandName && LinuxEnvironment.supported) {
      return _runShell(call.arguments);
    }
    final parsed = parseName(call.name);
    final server = parsed == null ? null : _serverById(parsed.$1);
    if (parsed == null || server == null) {
      return ToolOutcome(
        'That MCP server is not configured any more, so this tool cannot run.',
        const ToolActivity('MCP', 'MCPサーバーが見つかりません', failed: true),
      );
    }
    final tool = parsed.$2;
    try {
      final text = await server.client.callTool(tool, call.arguments);
      return ToolOutcome(
        text,
        ToolActivity('MCP', '${server.config.name}: $tool を実行'),
      );
    } catch (e) {
      return ToolOutcome(
        'The MCP tool failed: $e',
        ToolActivity(
          'MCP',
          '${server.config.name}: $tool に失敗: $e',
          failed: true,
        ),
      );
    }
  }

  // ---------------------------------------------------------------- ci_status

  /// Reads GitHub Actions for the model: the newest runs of a branch, or the jobs of one run with
  /// the steps that failed. The GitHub MCP server has no Actions tools, so this reads the REST API.
  Future<ToolOutcome> _runCiStatus(Map<String, Object?> arguments) async {
    final repository = '${arguments['repository'] ?? ''}'.trim();
    final branch = '${arguments['branch'] ?? ''}'.trim();
    final limitWanted = arguments['limit'];
    final limit = (limitWanted is num ? limitWanted.toInt() : 10).clamp(1, 30);
    final runId = arguments['run_id'];
    try {
      final client = CiClient(token: ciToken);
      if (runId is num) {
        final jobs = await client.jobs(runId.toInt(), repository: repository);
        final failed = jobs.where((j) => j.failed).toList();
        final buffer = StringBuffer('Run ${runId.toInt()} のジョブ（${jobs.length} 件、失敗 ${failed.length} 件）:\n');
        for (final job in jobs) {
          buffer.writeln('- ${job.describe()}');
        }
        if (jobs.isNotEmpty && failed.isEmpty && jobs.every((j) => j.status == 'completed')) {
          buffer.writeln('→ すべて成功しました。');
        }
        return ToolOutcome(
          buffer.toString().trimRight(),
          ToolActivity('CI', 'Run ${runId.toInt()}: ジョブ ${jobs.length} 件（失敗 ${failed.length} 件）', failed: failed.isNotEmpty),
        );
      }
      final runs = await client.runs(branch: branch, repository: repository, limit: limit);
      if (runs.isEmpty) {
        return const ToolOutcome('この条件のワークフローの実行はありませんでした。', ToolActivity('CI', '実行なし'));
      }
      final buffer = StringBuffer('直近の実行（${runs.length} 件${branch.isEmpty ? '' : '、ブランチ $branch'}）:\n');
      for (final run in runs) {
        buffer.writeln('- ${run.describe()}${run.url == null ? '' : '  ${run.url}'}');
      }
      buffer.writeln('失敗した実行は run_id を渡すと、失敗したステップまで出します。');
      final red = runs.where((r) => r.conclusion == 'failure' || r.conclusion == 'timed_out').length;
      return ToolOutcome(
        buffer.toString().trimRight(),
        ToolActivity('CI', '直近 ${runs.length} 件（赤 $red 件）', failed: red > 0),
      );
    } catch (e) {
      return ToolOutcome(
        'CI を読めませんでした: $e',
        ToolActivity('CI', '読めませんでした: $e', failed: true),
      );
    }
  }

  // ---------------------------------------------------------------- run_command

  /// The Ubuntu Base 24.04.5 for arm64 that was checked on 2026-10-28 (29,936,675 bytes; the
  /// SHA-256 matches the `SHA256SUMS` beside it and a real download). The workspace is the 2 GB the
  /// user asked for. Every one of these becomes a setting (docs 19.5, step 3).
  static const _shellConfig = LinuxConfig(
    rootfsUrl:
        'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz',
    rootfsSha256: 'a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2',
    dns: ['1.1.1.1', '8.8.8.8'],
    workspaceLimitMb: 2048,
  );

  /// A command that runs longer is stopped; the model may ask for up to [_shellMaxTimeoutSeconds].
  static const _shellTimeoutSeconds = 120;
  static const _shellMaxTimeoutSeconds = 600;
  static const _shellMaxOutputChars = 20000;

  /// One environment for the whole app: the workspace is shared by every chat, and the Android side
  /// runs one command at a time, so the state of an install must not be lost between turns.
  static final LinuxEnvironment _shell = LinuxEnvironment();

  /// Runs the arguments of `Protocol.runCommand` and turns the result into what the model reads.
  Future<ToolOutcome> _runShell(Map<String, Object?> arguments) async {
    final command = '${arguments['command'] ?? ''}'.trim();
    if (command.isEmpty) {
      return const ToolOutcome(
        'The command is empty.',
        ToolActivity('Shell', '空のコマンド', failed: true),
      );
    }
    final cwd = '${arguments['cwd'] ?? '/workspace'}'.trim();
    final wanted = arguments['timeout_seconds'];
    final asked = wanted is num ? wanted.toInt() : _shellTimeoutSeconds;
    final seconds = asked.clamp(1, _shellMaxTimeoutSeconds).toInt();
    try {
      // the first command installs the environment; the user approved this call already
      if (!_shell.ready) {
        await _shell.refresh(_shellConfig);
        if (!_shell.ready) await _shell.install(_shellConfig);
      }
      final outcome = await _shell.run(
        config: _shellConfig,
        command: command,
        cwd: cwd,
        timeoutSeconds: seconds,
        maxOutputChars: _shellMaxOutputChars,
      );
      return ToolOutcome(
        outcome.describe(),
        ToolActivity('Shell', '\$ $command', failed: !outcome.ok),
      );
    } catch (e) {
      return ToolOutcome(
        'The command could not be run: $e',
        ToolActivity('Shell', '実行できませんでした: $e', failed: true),
      );
    }
  }
}
