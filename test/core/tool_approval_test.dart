import 'package:arce_ai/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool needs(String name) => ToolApproval.needsApproval(name);

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
    ]) {
      expect(needs(read), isFalse, reason: read);
    }
  });

  test('the id of the server is not read as part of the tool name', () {
    expect(needs('mcp_update-tracker__list_items'), isFalse);
    expect(needs('mcp_update-tracker__delete_item'), isTrue);
  });
}
