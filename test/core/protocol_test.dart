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

  test('a tool call that is not JSON says what it looked like, so the cause can be read from the screen', () {
    final result = ToolCallParser.parse('{"name":"web_search","arguments":{"query":"a"}}{"name":"web_search"', [Protocol.webSearch]);
    expect(result, isA<ParseInvalid>());
    final reason = (result as ParseInvalid).reason;
    expect(reason, startsWith('not JSON: '));
    expect(reason, contains('{"name":"web_search","arguments":{"query":"a"}}{'));
  });

  group('delegate（分担の道具）', () {
    ParseResult parse(String arguments) => ToolCallParser.parse('{"name":"delegate","arguments":$arguments}', [Protocol.delegate]);

    test('要約とタスクを読む。revise と files も', () {
      final ok = parse('{"summary":"S","tasks":[{"title":"A","instructions":"Aを作る","files":["a.py"," "],"revise":"d2"},{"title":"B","instructions":"Bを作る"}]}') as ParseOk;
      final call = ok.call as Delegate;
      expect(call.summary, 'S');
      expect(call.tasks.map((t) => t.title), ['A', 'B']);
      expect(call.tasks.first.files, ['a.py'], reason: 'a blank file name is dropped');
      expect(call.tasks.first.revise, 'd2');
      expect(call.tasks.last.revise, isNull);
    });

    test('要約は無くてもよい。タイトルが無ければ番号で補う', () {
      final call = (parse('{"tasks":[{"instructions":"やる"}]}') as ParseOk).call as Delegate;
      expect(call.summary, isEmpty);
      expect(call.tasks.single.title, 'タスク 1');
    });

    test('指示の無いタスクと、タスクが空の依頼は受け付けない', () {
      expect(parse('{"tasks":[{"title":"A","instructions":"  "}]}'), isA<ParseInvalid>());
      expect(parse('{"tasks":[]}'), isA<ParseInvalid>());
    });

    test('道具の定義は、タスクの数に上限があり、指示を必須にする（ローカルの文法が守らせる）', () {
      final tasks = (Protocol.delegate.parameters['properties']! as Map)['tasks']! as Map;
      expect(tasks['maxItems'], Protocol.maxDelegateTasks);
      expect(((tasks['items']! as Map)['required']! as List), containsAll(['title', 'instructions']));
      expect(Protocol.toolCallSchema([Protocol.delegate, Protocol.webSearch]), isNotEmpty);
    });
  });
}
