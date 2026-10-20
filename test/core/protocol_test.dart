import 'package:arce_ai/core/app_settings_spec.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final tools = [Protocol.askUser];

  test('parses a question tile', () {
    final result = ToolCallParser.parse(
      '{"name":"ask_user","arguments":{"title":"言語は？","options":["Kotlin","Java"],"multi_select":true}}',
      tools,
    );
    final call = (result as ParseOk).call as AskUser;
    expect(
      call.tile,
      const QuestionTile(title: '言語は？', options: ['Kotlin', 'Java'], allowFreeInput: false, multiSelect: true),
    );
  });

  test('rejects tools the agent may not use', () {
    expect(ToolCallParser.parse('{"name":"delete_files","arguments":{}}', tools), isA<ParseInvalid>());
  });

  test('rejects content the grammar cannot rule out', () {
    for (final body in [
      '{"name":"ask_user","arguments":{"title":" ","options":["a"]}}',
      '{"name":"ask_user","arguments":{"title":"q","options":["a","a"]}}',
      '{"name":"ask_user","arguments":{"title":"q","options":["a",""]}}',
      '{"name":"ask_user","arguments":{"title":"q","options":"a"}}',
      '{"name":"ask_user","arguments":{"title":{"x":1},"options":["a"]}}',
      'not json',
    ]) {
      expect(ToolCallParser.parse(body, tools), isA<ParseInvalid>(), reason: body);
    }
  });

  test('tool call schema restricts name and arguments per tool', () {
    final schema = Protocol.toolCallSchema(tools);
    final variant = (schema['oneOf']! as List).single as Map;
    final props = variant['properties'] as Map;
    expect((props['name'] as Map)['const'], 'ask_user');
    expect(props['arguments'], Protocol.askUser.parameters);
  });

  group('app settings', () {
    final settingsTools = [Protocol.getAppSettings, Protocol.setAppSetting];

    test('reads every setting', () {
      final call = (ToolCallParser.parse('{"name":"get_app_settings","arguments":{}}', settingsTools) as ParseOk).call;
      expect(call, isA<GetAppSettings>());
    });

    test('a change carries the checked value', () {
      final call = (ToolCallParser.parse(
        '{"name":"set_app_setting","arguments":{"key":"contextLength","value":"8192"}}',
        settingsTools,
      ) as ParseOk)
          .call as SetAppSetting;
      expect(call.change.spec.key, 'contextLength');
      expect(call.change.value, 8192);
      expect(call.change.display, '8192');

      final theme = (ToolCallParser.parse(
        '{"name":"set_app_setting","arguments":{"key":"theme","value":"dark"}}',
        settingsTools,
      ) as ParseOk)
          .call as SetAppSetting;
      expect(theme.change.value, 'dark');

      final search = (ToolCallParser.parse(
        '{"name":"set_app_setting","arguments":{"key":"searchEnabled","value":"off"}}',
        settingsTools,
      ) as ParseOk)
          .call as SetAppSetting;
      expect(search.change.value, isFalse);
    });

    test('rejects keys and values the settings page would not accept', () {
      for (final arguments in [
        '{"key":"contextLength","value":"999999"}', // outside the range
        '{"key":"contextLength","value":"lots"}',
        '{"key":"theme","value":"neon"}',
        '{"key":"searchEnabled","value":"maybe"}',
        '{"key":"githubToken","value":"x"}', // unknown
        '{"key":"lastModelPath","value":"/sdcard/x.gguf"}', // read-only
        '{"key":"","value":"1"}',
      ]) {
        expect(
          ToolCallParser.parse('{"name":"set_app_setting","arguments":$arguments}', settingsTools),
          isA<ParseInvalid>(),
          reason: arguments,
        );
      }
    });

    test('the approval card offers 承認 and 拒否 only', () {
      final change = SettingsCatalog.parse('theme', 'dark')!;
      final tile = SettingsApproval.tile(change);
      expect(tile.options, [SettingsApproval.approve, SettingsApproval.reject]);
      expect(tile.title, contains('テーマ'));
      expect(tile.title, contains('dark'));
      expect(tile.allowFreeInput, isFalse);
      expect(SettingsApproval.isApproval([SettingsApproval.approve]), isTrue);
      expect(SettingsApproval.isApproval([SettingsApproval.reject]), isFalse);
    });

    test('every settable key is described for the model', () {
      final keys = SettingsCatalog.keysForPrompt();
      expect(keys, contains('contextLength'));
      expect(keys, isNot(contains('lastModelPath')));
    });
  });

  test('an agent without tools has no tool call schema', () {
    expect(() => Protocol.toolCallSchema([]), throwsArgumentError);
  });
}
