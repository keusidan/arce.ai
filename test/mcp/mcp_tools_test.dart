import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/mcp/mcp_client.dart';
import 'package:arce_ai/mcp/mcp_server.dart';
import 'package:arce_ai/mcp/mcp_tools.dart';
import 'package:arce_ai/services/linux_env.dart';
import 'package:flutter_test/flutter_test.dart';

import '../services/linux_env_test.dart' show FakeBridge;

/// A server that answers from a list, and records the calls it got.
class _FakeClient extends McpClient {
  _FakeClient(this.tools) : super(url: 'https://fake.example/mcp');

  final List<McpTool> tools;
  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<List<McpTool>> listTools() async => tools;

  @override
  Future<String> callTool(String name, Map<String, Object?> arguments) async {
    calls.add((name, arguments));
    return 'done: $name';
  }
}

McpTool _tool(String name, String description) => McpTool(
      name: name,
      description: description,
      parameters: {
        'type': 'object',
        'properties': {'path': {'type': 'string'}},
      },
    );

McpServerClient _server(String id, _FakeClient client, {String? name}) =>
    McpServerClient(McpServerConfig(id: id, name: name ?? id, url: 'https://fake.example/mcp'), client);

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

    // a tool the user chose not to be asked about again is not asked about; the others still are
    final remembered = McpTools(servers, approved: {'mcp_a__push_files'});
    expect(remembered.approvalRequired('mcp_a__push_files'), isFalse);
    expect(remembered.approvalRequired('mcp_a__delete_file'), isTrue);
    // a name that cannot be remembered (a command) is not let through by the list
    expect(ToolApproval.canRemember(Protocol.runCommandName), isFalse);
    final listed = McpTools(servers, approved: {'web_search', 'mcp_nobody__push_files'});
    expect(listed.approvalRequired('mcp_a__push_files'), isTrue, reason: 'only the tool named in the list is let through');
  });

  group('on demand', () {
    // thirty tools with long descriptions: the definitions alone are thousands of tokens
    final many = [for (var i = 0; i < 30; i++) _tool('tool_$i', 'Does thing number $i. ${'It does it with great care and detail. ' * 12}')];

    test('definitions too big to send each time are replaced by the three tools that look a tool up and call it', () async {
      final client = _FakeClient(many);
      final tools = McpTools([_server('big', client, name: 'Big Server')], onDemand: true, onDemandTokens: 2000);
      final names = [for (final d in await tools.definitions()) d.name];
      expect(names, containsAll([Protocol.mcpFindName, Protocol.mcpDescribeName, Protocol.mcpCallName]));
      expect(names.where((n) => n.startsWith('mcp_big__')), isEmpty, reason: 'no definition of the server\'s own tools');
      final find = (await tools.definitions()).firstWhere((d) => d.name == Protocol.mcpFindName);
      expect(find.description, contains('big (Big Server, 30 tools)'), reason: 'the model is told that something exists');
    });

    test('small definitions, the setting off, or no tools: everything goes as before', () async {
      final few = _FakeClient([_tool('a', 'x'), _tool('b', 'y')]);
      final small = McpTools([_server('s', few)], onDemand: true, onDemandTokens: 2000);
      expect([for (final d in await small.definitions()) d.name], containsAll(['mcp_s__a', 'mcp_s__b']));
      expect([for (final d in await small.definitions()) d.name], isNot(contains(Protocol.mcpFindName)));

      final off = McpTools([_server('big', _FakeClient(many))], onDemand: false);
      expect((await off.definitions()).where((d) => d.name.startsWith('mcp_big__')), hasLength(30));

      final none = McpTools(const [], onDemand: true, onDemandTokens: 0);
      expect([for (final d in await none.definitions()) d.name], isNot(contains(Protocol.mcpFindName)));
    });

    test('a threshold of 0 means always', () async {
      final tools = McpTools([_server('s', _FakeClient([_tool('a', 'x')]))], onDemand: true, onDemandTokens: 0);
      expect([for (final d in await tools.definitions()) d.name], contains(Protocol.mcpFindName));
    });

    test('mcp_find lists the tools with a short description, or only those that match, or one server\'s', () async {
      final tools = McpTools([
        _server('a', _FakeClient([_tool('push_files', 'Push files to a repository.\nMore text.'), _tool('read_file', 'Read a file')])),
        _server('b', _FakeClient([_tool('push_notes', 'Push a note')])),
      ]);
      final all = await tools.run(const McpCall(Protocol.mcpFindName, {}));
      expect(all.response, startsWith('3 of 3 tools'));
      expect(all.response, contains('mcp_a__push_files: Push files to a repository.'));
      expect(all.response, isNot(contains('More text')), reason: 'the first line only');

      final push = await tools.run(const McpCall(Protocol.mcpFindName, {'query': 'PUSH'}));
      expect(push.response, startsWith('2 of 3 tools match "push"'));
      expect(push.response, isNot(contains('read_file')));

      final one = await tools.run(const McpCall(Protocol.mcpFindName, {'query': 'push', 'server': 'b'}));
      expect(one.response, contains('mcp_b__push_notes'));
      expect(one.response, isNot(contains('mcp_a__')));

      final none = await tools.run(const McpCall(Protocol.mcpFindName, {'query': 'zzz'}));
      expect(none.response, contains('0 of 3 tools match'));
    });

    test('what mcp_find and mcp_describe answer is cut at the length the user set', () async {
      final tools = McpTools([_server('big', _FakeClient(many))], resultMaxChars: 500);
      final found = await tools.run(const McpCall(Protocol.mcpFindName, {}));
      expect(found.response, contains('characters left out'));
      expect(found.response.length, lessThan(700));
    });

    test('mcp_describe gives the definition of one tool, and says when there is none', () async {
      final tools = McpTools([_server('a', _FakeClient([_tool('push_files', 'Push files.')]))]);
      final ok = await tools.run(const McpCall(Protocol.mcpDescribeName, {'tool': 'mcp_a__push_files'}));
      expect(ok.response, contains('name: mcp_a__push_files'));
      expect(ok.response, contains('Push files.'));
      expect(ok.response, contains('"path":{"type":"string"}'));
      expect(ok.activity.failed, isFalse);

      for (final bad in ['mcp_a__nothing', 'mcp_zzz__x', 'run_command', '']) {
        final out = await tools.run(McpCall(Protocol.mcpDescribeName, {'tool': bad}));
        expect(out.activity.failed, isTrue, reason: bad);
        expect(out.response, contains('No such tool'));
      }
    });

    test('a tool called through mcp_call runs on its server, and is asked about like itself', () async {
      final client = _FakeClient([_tool('push_files', 'Push files.')]);
      final tools = McpTools([_server('a', client)], onDemand: true, onDemandTokens: 0);
      const wrapped = McpCall(Protocol.mcpCallName, {'tool': 'mcp_a__push_files', 'arguments': {'path': 'x'}});
      final call = wrapped.unwrapped;
      expect(tools.approvalRequired(call.name, call.arguments), isTrue, reason: 'a push still waits for the user');
      final out = await tools.run(call);
      expect(client.calls.single.$1, 'push_files');
      expect(client.calls.single.$2, {'path': 'x'});
      expect(out.response, 'done: push_files');
      // a wrapper that was not turned into a real call has nothing to run
      final loose = await tools.run(const McpCall(Protocol.mcpCallName, {'tool': 'run_command'}));
      expect(loose.activity.failed, isTrue);
    });
  });

  group('secrets for commands', () {
    const token = 'ghp_ExampleTokenValue123';
    late FakeBridge bridge;
    late LinuxEnvironment env;

    McpTools make({Map<String, String> secrets = const {token: ''}, ShellSettings shell = const ShellSettings()}) {
      return McpTools(
        const [],
        shell: shell,
        secrets: secrets,
        environment: env,
        shellSupported: true,
      );
    }

    setUp(() {
      bridge = FakeBridge()..installed = true;
      env = LinuxEnvironment(bridge: bridge, android: true);
    });

    test('the model is told the names, never the values', () async {
      final tools = make(secrets: {'GITHUB_TOKEN': token, 'NPM_TOKEN': 'npm_secret_value'});
      final definition = (await tools.definitions()).firstWhere((d) => d.name == Protocol.runCommandName);
      expect(definition.description, contains('GITHUB_TOKEN, NPM_TOKEN'));
      expect(definition.description, isNot(contains(token)));
      expect(definition.description, isNot(contains('npm_secret_value')));
      final plain = (await make(secrets: {}).definitions()).firstWhere((d) => d.name == Protocol.runCommandName);
      expect(plain.description, isNot(contains('Stored secrets')));
    });

    test('a command that is given a secret is always approved first, even one that stays in the sandbox', () {
      final tools = make(secrets: {'GITHUB_TOKEN': token});
      expect(tools.approvalRequired(Protocol.runCommandName, {'command': 'ls', 'cwd': '/workspace'}), isFalse, reason: 'inside the sandbox, no secret: runs');
      expect(tools.approvalRequired(Protocol.runCommandName, {'command': 'ls', 'cwd': '/workspace', 'secrets': ['GITHUB_TOKEN']}), isTrue);
      expect(tools.approvalRequired(Protocol.runCommandName, {'command': 'ls', 'secrets': 'GITHUB_TOKEN'}), isTrue, reason: 'a malformed list asks too');
      expect(tools.approvalRequired(Protocol.runCommandName, {'command': 'ls', 'secrets': <String>[]}), isFalse);
    });

    test('the value goes to the command that asked for it, and only that; the output has it taken out', () async {
      bridge.runAnswer = {'exit': 0, 'stdout': 'GITHUB_TOKEN=$token\nNPM=npm_secret_value\n', 'stderr': '', 'elapsedMs': 5};
      final tools = make(secrets: {'GITHUB_TOKEN': token, 'NPM_TOKEN': 'npm_secret_value'});
      final out = await tools.run(const McpCall(Protocol.runCommandName, {'command': 'env', 'secrets': ['GITHUB_TOKEN']}));
      expect(bridge.lastRun!['secrets'], {'GITHUB_TOKEN': token}, reason: 'NPM_TOKEN was not asked for');
      expect(out.response, contains('[GITHUB_TOKEN]'));
      expect(out.response, isNot(contains(token)));
      expect(out.response, contains('npm_secret_value'), reason: 'a secret that was not given is not in the output to take out');
      expect(out.activity.summary, contains('秘密: GITHUB_TOKEN'));
      expect(out.activity.summary, isNot(contains(token)));
    });

    test('a command without secrets gets none', () async {
      final tools = make(secrets: {'GITHUB_TOKEN': token});
      await tools.run(const McpCall(Protocol.runCommandName, {'command': 'ls'}));
      expect(bridge.lastRun!['secrets'], isEmpty);
    });

    test('a name that is not available stops the command before it runs, and says which names are', () async {
      final tools = make(secrets: {'GITHUB_TOKEN': token});
      final out = await tools.run(const McpCall(Protocol.runCommandName, {'command': 'env', 'secrets': ['AWS_SECRET']}));
      expect(bridge.calls, isNot(contains('run')));
      expect(out.activity.failed, isTrue);
      expect(out.response, contains('AWS_SECRET'));
      expect(out.response, contains('Available: GITHUB_TOKEN'));
      expect(out.response, contains('Nothing was run'));

      final none = await make(secrets: {}).run(const McpCall(Protocol.runCommandName, {'command': 'env', 'secrets': ['X']}));
      expect(none.response, contains('The user has made none available'));

      final odd = await tools.run(const McpCall(Protocol.runCommandName, {'command': 'env', 'secrets': 'GITHUB_TOKEN'}));
      expect(odd.activity.failed, isTrue);
      expect(bridge.calls, isNot(contains('run')));
    });
  });
}
