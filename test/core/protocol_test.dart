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

  test('an agent without tools has no tool call schema', () {
    expect(() => Protocol.toolCallSchema([]), throwsArgumentError);
  });
}
