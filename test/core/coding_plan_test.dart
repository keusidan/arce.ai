import 'package:arce_ai/core/coding_plan.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  group('プランナーに伝えること', () {
    test('分け方も、直させるかも、プランナーが決める。アプリは上限と使い方だけを伝える', () {
      final text = CodingPrompts.plannerInstructions(maxTasks: 3, reviewRounds: 2);
      expect(text, contains('delegate'));
      expect(text, contains('At most 3 tasks'));
      expect(text, contains('revise'));
      expect(text, contains('at most 2 times'));
      expect(text, contains('Do not copy them into your answer'), reason: 'the user already sees the developers\' files');
      expect(text, contains('answer yourself'), reason: 'a small job is not delegated');
    });

    test('直しの回数が 0 なら、直させないと伝える', () {
      final text = CodingPrompts.plannerInstructions(maxTasks: 4, reviewRounds: 0);
      expect(text, contains('Do not send work back'));
      expect(text, isNot(contains('revise set to')));
    });
  });

  group('開発モデルに渡すこと', () {
    test('計画の要約と、そのタスクだけ。ほかのタスクは見せない', () {
      const first = DelegateTask(title: 'A', instructions: 'Aを作る', files: ['a.py']);
      final text = CodingPrompts.developerTask('共有の決めごと', first);
      expect(text, contains('共有の決めごと'));
      expect(text, contains('Aを作る'));
      expect(text, contains('a.py'));
      expect(text, isNot(contains('Bを作る')));
    });

    test('要約が空なら、その見出しは出さない', () {
      final text = CodingPrompts.developerTask('  ', const DelegateTask(title: 'A', instructions: 'Aを作る'));
      expect(text, isNot(contains('The plan')));
    });

    test('直しの依頼は、直す内容と「完全なファイルで」を伝える', () {
      final text = CodingPrompts.correction('  関数名を add に  ');
      expect(text, contains('関数名を add に'));
      expect(text, contains('complete corrected files'));
    });
  });
}
