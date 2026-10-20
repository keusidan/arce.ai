import 'package:flutter_test/flutter_test.dart';

import 'package:arce_ai/core/toolchain/java_source.dart';

void main() {
  group('JavaSource.parse', () {
    test('クラス名からファイル名を決める', () {
      final src = JavaSource.parse('class Hello { }');
      expect(src.primaryClass, 'Hello');
      expect(src.fileName, 'Hello.java');
      expect(src.packageName, isNull);
      expect(src.mainClass, isNull);
      expect(src.activityClass, isNull);
    });

    test('public なクラスを優先する（ファイル名を決めるため）', () {
      final src = JavaSource.parse('class Helper { }\npublic class Main { }');
      expect(src.primaryClass, 'Main');
      expect(src.fileName, 'Main.java');
    });

    test('package 宣言を拾う', () {
      final src = JavaSource.parse('package com.example.app;\n\npublic class Main { }');
      expect(src.packageName, 'com.example.app');
    });

    test('main を持つクラスを完全修飾名で返す', () {
      final src = JavaSource.parse('''
package com.example.app;
class Util { }
public class Main {
  public static void main(String[] args) { }
}
''');
      expect(src.mainClass, 'com.example.app.Main');
    });

    test('main は直前にあるクラスに属する', () {
      final src = JavaSource.parse('''
class A { }
class B {
  public static void main(final String[] args) { }
}
class C { }
''');
      expect(src.mainClass, 'B');
    });

    test('main の引数の書き方を受け付ける（配列・可変長・変数名なし）', () {
      expect(JavaSource.parse('class A { public static void main(String[] a) {} }').mainClass, 'A');
      expect(JavaSource.parse('class A { public static void main(String... a) {} }').mainClass, 'A');
      expect(JavaSource.parse('class A { public static void main(java.lang.String[] a) {} }').mainClass,
          isNull);
    });

    test('コメントの中の main は無視する', () {
      final src = JavaSource.parse('''
class A {
  // public static void main(String[] args) { }
  /* public static void main(String[] args) { } */
}
''');
      expect(src.mainClass, isNull);
    });

    test('文字列リテラルの中身に惑わされない', () {
      final src = JavaSource.parse('''
class A {
  String s = "class Fake { public static void main(String[] args) {} }";
}
''');
      expect(src.primaryClass, 'A');
      expect(src.mainClass, isNull);
    });

    test('Activity を継承したクラスを完全修飾名で返す', () {
      final src = JavaSource.parse('''
package com.example.app;
public class MainActivity extends Activity { }
''');
      expect(src.activityClass, 'com.example.app.MainActivity');
      expect(src.primaryClass, 'MainActivity');
    });

    test('android.app.Activity の完全修飾でも拾う', () {
      final src = JavaSource.parse('class Main extends android.app.Activity { }');
      expect(src.activityClass, 'Main');
    });

    test('ListActivity も Activity とみなす', () {
      final src = JavaSource.parse('class List extends ListActivity { }');
      expect(src.activityClass, 'List');
    });

    test('クラス宣言が無ければ例外', () {
      expect(() => JavaSource.parse('int x = 1;'), throwsArgumentError);
    });
  });

  group('withPackage', () {
    test('package が無ければ付ける', () {
      final src = JavaSource.parse('class Main { }').withPackage('ai.arce.generated');
      expect(src.packageName, 'ai.arce.generated');
      expect(src.primaryClass, 'Main');
      expect(src.code, startsWith('package ai.arce.generated;'));
    });

    test('package があればそのまま', () {
      final original = JavaSource.parse('package com.example;\nclass Main { }');
      expect(identical(original.withPackage('ai.arce.generated'), original), isTrue);
      expect(original.withPackage('ai.arce.generated').packageName, 'com.example');
    });
  });

  test('Java のレベルは 1.8（端末内の ECJ が扱える上限）', () {
    expect(JavaSource.javaLevel, '1.8');
  });
}
