import 'dart:convert';

import '../ai/token_budget.dart';
import '../core/protocol.dart';
import '../core/tool_runtime.dart';
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
class McpTools {
  McpTools(this._servers, {Map<String, List<McpTool>>? cache})
    : _cache = cache ?? {};

  final List<McpServerClient> _servers;
  final Map<String, List<McpTool>> _cache;

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
    final out = <ToolDefinition>[];
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
}
