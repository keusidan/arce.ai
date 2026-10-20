import 'package:flutter_test/flutter_test.dart';

import 'package:arce_ai/core/sandbox.dart';

void main() {
  group('SandboxResult', () {
    test('JSON を往復できる', () {
      const original = SandboxResult(true, 'hello', timedOut: false);
      final restored = SandboxResult.fromJson(original.toJson());
      expect(restored.ok, isTrue);
      expect(restored.output, 'hello');
      expect(restored.timedOut, isFalse);
    });

    test('タイムアウトも往復できる', () {
      const original = SandboxResult(false, '20秒の制限時間を超えたため停止しました', timedOut: true);
      final restored = SandboxResult.fromJson(original.toJson());
      expect(restored.ok, isFalse);
      expect(restored.timedOut, isTrue);
    });

    test('欠けた項目は失敗として読む（ブリッジが落ちても安全側）', () {
      final restored = SandboxResult.fromJson(const {});
      expect(restored.ok, isFalse);
      expect(restored.output, '');
      expect(restored.timedOut, isFalse);
    });

    test('出力の上限は Kotlin 版と同じ 64 KiB', () {
      expect(SandboxResult.maxOutput, 64 * 1024);
    });
  });

  group('NoSandbox', () {
    test('Python は「実行できない」を返し、例外にしない', () async {
      final result = await const NoSandbox().runPython('print(1)');
      expect(result.ok, isFalse);
      expect(result.timedOut, isFalse);
      expect(result.output, contains('Android'));
    });

    test('dex も同じ', () async {
      final result = await const NoSandbox().runDex(const [1, 2, 3], 'Main');
      expect(result.ok, isFalse);
      expect(result.output, contains('Android'));
    });

    test('既定のタイムアウトは 20 秒', () {
      expect(sandboxDefaultTimeout, const Duration(seconds: 20));
    });
  });
}
