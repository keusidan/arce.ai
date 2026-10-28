import 'package:arce_ai/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool needs(String name, [Map<String, Object?> args = const {}]) =>
      ToolApproval.needsApproval(name, args);


  test('tools that change something outside the device ask first, whatever the naming style', () {
    for (final write in [
      'mcp_github__create_or_update_file',
      'mcp_github__push_files',
      'mcp_github__merge_pull_request',
      'mcp_kaggle__CreateBenchmarkTaskFromPrompt',
      'mcp_kaggle__SubmitToCompetition',
      'mcp_kaggle__StartNotebookSession',
      'mcp_kaggle__CancelNotebookSession',
      'mcp_kaggle__UploadModelFile',
      'mcp_x__runQuery',
    ]) {
      expect(needs(write), isTrue, reason: write);
    }
  });

  test('reads do not ask: a word that merely contains a verb is not a verb', () {
    for (final read in [
      'mcp_kaggle__ListDatasets',
      'mcp_kaggle__GetDatasetMetadata',
      'mcp_kaggle__SearchCompetitions',
      'mcp_kaggle__GetBenchmarkLeaderboard',
      'mcp_kaggle__DownloadModelFiles',
      'mcp_github__list_issues',
      'mcp_github__get_file_contents',
      'mcp_github__search_code',
      Protocol.ciStatusName,
    ]) {
      expect(needs(read), isFalse, reason: read);
    }
  });

  test('the id of the server is not read as part of the tool name', () {
    expect(needs('mcp_update-tracker__list_items'), isFalse);
    expect(needs('mcp_update-tracker__delete_item'), isTrue);
  });

  test('run_command inside the environment runs without asking; one that reaches outside asks', () {
    expect(
      needs(Protocol.runCommandName, {'command': 'git status && ls -la', 'cwd': '/workspace'}),
      isFalse,
      reason: 'a command confined to /workspace runs without asking',
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'apt-get install -y git'}),
      isFalse,
      reason: 'no cwd means /workspace',
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'pytest', 'cwd': '/workspace/app', 'auto_execute': true}),
      isFalse,
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'rm -rf /workspace/tmp', 'auto_execute': false}),
      isTrue,
      reason: 'the model can ask for a look first',
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'ls', 'cwd': '/sdcard/Download'}),
      isTrue,
      reason: 'host Android storage is outside the environment',
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'cat /sdcard/secret.txt', 'cwd': '/workspace'}),
      isTrue,
      reason: 'naming a host path in the command asks first',
    );
    expect(
      needs(Protocol.runCommandName, {'command': 'ls', 'cwd': '/workspace/../../etc'}),
      isTrue,
      reason: 'a path that climbs above the root is refused',
    );
  });
}
