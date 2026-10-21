import 'package:arce_ai/mcp/mcp_client.dart';
import 'package:arce_ai/mcp/mcp_server.dart';
import 'package:arce_ai/mcp/mcp_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('道具名はサーバー id と道具名に分けられる', () {
    final name = McpTools.toolName('github', 'create_issue');
    expect(name, 'mcp_github__create_issue');
    expect(McpTools.parseName(name), ('github', 'create_issue'));
    // a tool name may contain the separator itself: only the first one splits
    expect(McpTools.parseName('mcp_github__a__b'), ('github', 'a__b'));
    expect(McpTools.parseName('mcp_'), isNull);
    expect(McpTools.parseName('mcp___x'), isNull);
    expect(McpTools.parseName('web_search'), isNull);
  });

  test('サーバーの id に __ は入らない', () {
    final id = McpServers.idFor('My__Server', const []);
    expect(id, 'my-server');
    expect(id.contains('__'), isFalse);
  });

  test('書き込み前の確認はサーバーごとに切り替えられる', () {
    final servers = [
      McpServerClient(
        const McpServerConfig(id: 'a', name: 'A', url: 'https://a.example/mcp'),
        McpClient(url: 'https://a.example/mcp'),
      ),
      McpServerClient(
        const McpServerConfig(
          id: 'b',
          name: 'B',
          url: 'https://b.example/mcp',
          approveWrites: false,
        ),
        McpClient(url: 'https://b.example/mcp'),
      ),
    ];
    final tools = McpTools(servers);
    expect(tools.approvalRequired('mcp_a__push_files'), isTrue);
    expect(tools.approvalRequired('mcp_b__push_files'), isFalse);
  });
}
