import 'package:arce_ai/core/coding_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('計画の読み取り', () {
    test('JSON の計画を、前後の文章やコードフェンスごと読める', () {
      const text = '''はい、こう分けます。
```json
{"summary": "Python の CLI", "tasks": [
  {"id": "t1", "title": "パーサ", "instructions": "parse() を作る", "files": ["parser.py"]},
  {"id": "t2", "title": "main", "instructions": "main.py から parse() を呼ぶ"}
]}
```''';
      final plan = CodingPrompts.parsePlan(text, maxTasks: 4)!;
      expect(plan.summary, 'Python の CLI');
      expect([for (final t in plan.tasks) t.id], ['t1', 't2']);
      expect(plan.tasks.first.files, ['parser.py']);
      expect(plan.tasks.last.files, isEmpty);
    });

    test('JSON が無い返事は計画ではない（質問や、小さすぎる依頼への直接の答え）', () {
      expect(CodingPrompts.parsePlan('どの言語で作りますか？', maxTasks: 4), isNull);
      expect(CodingPrompts.parsePlan('print("hi")  # {}', maxTasks: 4), isNull);
      expect(CodingPrompts.parsePlan('{"summary": "x", "tasks": []}', maxTasks: 4), isNull, reason: 'no tasks');
      expect(CodingPrompts.parsePlan('{壊れた', maxTasks: 4), isNull);
    });

    test('タスクの数は上限まで。指示の無いタスクは捨てる', () {
      final text = '{"summary": "", "tasks": [${[
        for (var i = 1; i <= 6; i++) '{"id": "t$i", "title": "T$i", "instructions": "do $i"}',
        '{"id": "x", "title": "empty"}',
      ].join(',')}]}';
      final plan = CodingPrompts.parsePlan(text, maxTasks: 3)!;
      expect(plan.tasks, hasLength(3));
      expect(
        CodingPrompts.parsePlan('{"tasks": [{"title": "a"}, {"instructions": "ok"}]}', maxTasks: 3)!.tasks.single.title,
        'タスク 1',
        reason: 'a task without a title gets one',
      );
    });

    test('id が無い・重なっているタスクには、重ならない id をつける', () {
      final plan = CodingPrompts.parsePlan(
        '{"tasks": [{"id": "a", "instructions": "1"}, {"id": "a", "instructions": "2"}, {"instructions": "3"}]}',
        maxTasks: 5,
      )!;
      final ids = [for (final t in plan.tasks) t.id];
      expect(ids.toSet(), hasLength(3));
    });
  });

  group('レビューの読み取り', () {
    test('修正の指示は、実在するタスクのものだけ受け取る', () {
      final review = CodingPrompts.parseReview(
        '{"approved": false, "notes": "型が合わない", "fixes": [{"task": "t2", "instructions": "int にする"}, {"task": "zzz", "instructions": "?"}]}',
        taskIds: {'t1', 't2'},
      );
      expect(review.approved, isFalse);
      expect(review.fixes, {'t2': 'int にする'});
      expect(review.notes, '型が合わない');
    });

    test('読めない返事は承認として扱う（やり直しを無駄に起こさない）', () {
      expect(CodingPrompts.parseReview('よさそうです', taskIds: {'t1'}).approved, isTrue);
      expect(CodingPrompts.parseReview('{壊れ', taskIds: {'t1'}).approved, isTrue);
    });

    test('approved:false でも直すところが無ければ承認と同じ', () {
      expect(CodingPrompts.parseReview('{"approved": false, "fixes": []}', taskIds: {'t1'}).approved, isTrue);
    });
  });

  group('設定と参照', () {
    test('provider|model の形を読む', () {
      expect(CodingSettings.parseRef('openai|gpt-4o'), ('openai', 'gpt-4o'));
      expect(CodingSettings.parseRef('local|'), ('local', ''));
      expect(CodingSettings.parseRef('deepinfra|deepseek-ai/DeepSeek|x'), ('deepinfra', 'deepseek-ai/DeepSeek|x'));
      expect(CodingSettings.parseRef(''), isNull);
      expect(CodingSettings.parseRef('|x'), isNull);
    });

    test('両方の役にモデルがあって、オンのときだけ使える', () {
      expect(const CodingSettings(enabled: true, planner: 'a|b', developer: 'c|d').isReady, isTrue);
      expect(const CodingSettings(enabled: false, planner: 'a|b', developer: 'c|d').isReady, isFalse);
      expect(const CodingSettings(enabled: true, planner: 'a|b').isReady, isFalse);
    });
  });

  test('開発モデルには、依頼・計画の要約・そのタスクだけを渡す', () {
    final plan = CodingPlan(summary: '共有の決めごと', tasks: const [
      CodingTask(id: 't1', title: 'A', instructions: 'Aを作る', files: ['a.py']),
      CodingTask(id: 't2', title: 'B', instructions: 'Bを作る'),
    ]);
    final text = CodingPrompts.developerTask('ツールを作って', plan, plan.tasks.first);
    expect(text, contains('ツールを作って'));
    expect(text, contains('共有の決めごと'));
    expect(text, contains('Aを作る'));
    expect(text, contains('a.py'));
    expect(text, isNot(contains('Bを作る')), reason: 'a developer does not see the other tasks');
  });

  test('レビューに渡す出力は、タスクごとに長さを切る', () {
    final plan = CodingPlan(summary: 's', tasks: const [CodingTask(id: 't1', title: 'A', instructions: 'i')]);
    final text = CodingPrompts.reviewInput('r', plan, {'t1': 'x' * 10000}, perTaskChars: 100);
    expect(text, contains('[… cut …]'));
    expect(text.length, lessThan(1000));
  });
}
