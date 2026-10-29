import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/shell_secrets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('names', () {
    test('an environment variable name: letters, digits and _, not starting with a digit; the names the app sets are taken', () {
      for (final ok in ['GITHUB_TOKEN', 'gh_token', '_X', 'A1', 'NPM_TOKEN']) {
        expect(ShellSecrets.validName(ok), isTrue, reason: ok);
      }
      for (final bad in ['', '1A', 'A-B', 'A B', 'A=B', 'HOME', 'path', 'LD_PRELOAD', 'BASH_ENV', 'PROOT_LOADER', 'あ', 'A' * 65]) {
        expect(ShellSecrets.validName(bad), isFalse, reason: bad);
      }
    });

    test('a secret is saved as a name and where its value comes from; a bad name is dropped when it is read', () {
      const own = ShellSecret(name: 'NPM_TOKEN');
      const mcp = ShellSecret(name: 'GITHUB_TOKEN', mcpServerId: 'github');
      expect(own.toJson(), {'name': 'NPM_TOKEN'}, reason: 'no value: that is in the secure storage');
      expect(mcp.toJson(), {'name': 'GITHUB_TOKEN', 'mcpServerId': 'github'});
      expect(ShellSecret.fromJson(mcp.toJson())!.mcpServerId, 'github');
      expect(ShellSecret.fromJson(own.toJson())!.fromMcp, isFalse);
      expect(ShellSecret.fromJson({'name': 'HOME'}), isNull);
      expect(ShellSecret.fromJson({'name': 5}), isNull);
      expect(ShellSecret.fromJson('x'), isNull);
    });
  });

  group('what a command asks for', () {
    test('a list of names, each once; nothing is nothing; anything else is refused', () {
      expect(ShellSecrets.names(null), isEmpty);
      expect(ShellSecrets.names([' A ', 'B', 'A', '']), ['A', 'B']);
      expect(ShellSecrets.names('A'), isNull);
      expect(ShellSecrets.names([1]), isNull);
    });
  });

  group('the output of a command that was given a secret', () {
    test('the value is replaced by its name; the longest first; a short value is left alone', () {
      final text = ShellSecrets.redact(
        'token=ghp_abcdef123456 and ghp_abcdef sk',
        {'GITHUB_TOKEN': 'ghp_abcdef123456', 'SHORT': 'ghp_abcdef', 'TINY': 'sk'},
      );
      expect(text, 'token=[GITHUB_TOKEN] and [SHORT] sk');
      expect(ShellSecrets.redact('nothing here', {'A': 'secret-value'}), 'nothing here');
    });
  });

  group('mcp_call', () {
    test('a call to a server\'s tool through mcp_call is that tool\'s call from then on', () {
      const wrapped = McpCall('mcp_call', {
        'tool': 'mcp_github__push_files',
        'arguments': {'path': 'a'},
      });
      final call = wrapped.unwrapped;
      expect(call.name, 'mcp_github__push_files');
      expect(call.arguments, {'path': 'a'});
      expect(ToolApproval.needsApproval(call.name, call.arguments), isTrue, reason: 'the approval sees the real tool');
      expect(ToolApproval.canRemember(call.name), isTrue);
    });

    test('the app\'s own tools cannot be reached through it', () {
      for (final tool in [Protocol.runCommandName, Protocol.ciStatusName, 'update_settings', 'mcp_call', 'mcp_x', 'mcp___x', 'mcp_x__']) {
        final call = McpCall('mcp_call', {'tool': tool, 'arguments': {'command': 'rm -rf /'}});
        expect(identical(call.unwrapped, call), isTrue, reason: tool);
      }
      const noTool = McpCall('mcp_call', {'arguments': {}});
      expect(identical(noTool.unwrapped, noTool), isTrue);
    });

    test('missing or odd arguments become none; another call is returned as it is', () {
      expect(const McpCall('mcp_call', {'tool': 'mcp_a__b'}).unwrapped.arguments, isEmpty);
      expect(const McpCall('mcp_call', {'tool': 'mcp_a__b', 'arguments': 'x'}).unwrapped.arguments, isEmpty);
      const other = McpCall('mcp_a__b', {'x': 1});
      expect(identical(other.unwrapped, other), isTrue);
    });
  });

  group('run_command with secrets', () {
    test('the definition offers a secrets list; the card names the secrets', () {
      final properties = Protocol.runCommand.parameters['properties'] as Map;
      expect((properties['secrets'] as Map)['type'], 'array');
      final tile = ToolApproval.tile(const McpCall(Protocol.runCommandName, {
        'command': 'git push',
        'secrets': ['GITHUB_TOKEN', 'NPM_TOKEN'],
      }));
      expect(tile.title, contains('秘密を渡します: GITHUB_TOKEN、NPM_TOKEN'));
      expect(ToolApproval.tile(const McpCall(Protocol.runCommandName, {'command': 'ls'})).title, isNot(contains('秘密')));
    });
  });
}
