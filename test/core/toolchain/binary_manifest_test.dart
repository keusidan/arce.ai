import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:arce_ai/core/toolchain/binary_manifest.dart';

void main() {
  final bytes = BinaryManifest.launcherApp(
    packageName: 'ai.arce.generated',
    label: 'Demo',
    activityClass: 'ai.arce.generated.MainActivity',
    minSdk: 31,
    targetSdk: 36,
  ).toBytes();
  final data = ByteData.sublistView(bytes);

  test('ファイルヘッダは XML チャンクで、長さが実体と一致する', () {
    expect(data.getUint16(0, Endian.little), 0x0003);
    expect(data.getUint16(2, Endian.little), 8);
    expect(data.getInt32(4, Endian.little), bytes.length);
  });

  test('文字列プールに必要な文字列が入っている', () {
    final pool = _stringPool(bytes);
    expect(pool, containsAll(<String>[
      'manifest',
      'application',
      'activity',
      'intent-filter',
      'action',
      'category',
      'uses-sdk',
      'ai.arce.generated',
      'ai.arce.generated.MainActivity',
      'android.intent.action.MAIN',
      'android.intent.category.LAUNCHER',
      'Demo',
    ]));
    // 名前空間は android 属性より後ろに置かれる（Kotlin 版と同じ並び）
    expect(pool.first, 'label');
  });

  test('文字列プールは 4 バイト境界に揃えられている', () {
    final pool = _chunk(bytes, 0x0001)!;
    expect(pool.size % 4, 0);
  });

  test('リソースマップは使った android 属性の ID を昇順で持つ', () {
    final ids = _resourceMap(bytes);
    expect(ids, [
      0x01010001, // label
      0x01010003, // name
      0x01010010, // exported
      0x0101020c, // minSdkVersion
      0x0101021b, // versionCode
      0x0101021c, // versionName
      0x01010270, // targetSdkVersion
    ]);
    // 昇順であること（フレームワークが ID で引くため）
    final sorted = [...ids]..sort();
    expect(ids, sorted);
  });

  test('要素の数だけ START/END が対になっている', () {
    expect(_countChunks(bytes, 0x0102), _countChunks(bytes, 0x0103));
    // manifest, uses-sdk, application, activity, intent-filter, action, category
    expect(_countChunks(bytes, 0x0102), 7);
  });

  test('名前空間の開始と終了が 1 組ずつある', () {
    expect(_countChunks(bytes, 0x0100), 1);
    expect(_countChunks(bytes, 0x0101), 1);
  });

  test('未知の android 属性は例外', () {
    expect(
      () => BinaryManifest.build('manifest', (e) => e.android('theme', 'x')),
      throwsArgumentError,
    );
  });

  test('android 以外の属性には String しか使えない', () {
    expect(
      () => BinaryManifest.build('manifest', (e) => e.attr('package', 'x').attr('n', 'y')),
      returnsNormally,
    );
  });

  test('同じ内容なら同じバイト列になる（再現性）', () {
    final again = BinaryManifest.launcherApp(
      packageName: 'ai.arce.generated',
      label: 'Demo',
      activityClass: 'ai.arce.generated.MainActivity',
      minSdk: 31,
      targetSdk: 36,
    ).toBytes();
    expect(again, equals(bytes));
  });

  group('整数・真偽値の属性', () {
    test('int は TYPE_INT_DEC、bool は TYPE_INT_BOOLEAN で書かれる', () {
      final typed = BinaryManifest.build('manifest', (e) {
        e.android('versionCode', 7);
        e.android('debuggable', true);
        e.android('exported', false);
      }).toBytes();
      final d = ByteData.sublistView(typed);
      final types = <int>[];
      final values = <int>[];
      for (var i = 0; i + 8 <= typed.length; i++) {
        // typed value: size(2)=8, res0(1)=0, type(1), data(4)
        if (d.getUint16(i, Endian.little) == 8 &&
            d.getUint8(i + 2) == 0 &&
            (d.getUint8(i + 3) == 0x10 || d.getUint8(i + 3) == 0x12)) {
          types.add(d.getUint8(i + 3));
          values.add(d.getInt32(i + 4, Endian.little));
        }
      }
      expect(types, containsAll(<int>[0x10, 0x12]));
      expect(values, containsAll(<int>[7, -1, 0]));
    });
  });
}

class _Chunk {
  const _Chunk(this.type, this.offset, this.size);
  final int type;
  final int offset;
  final int size;
}

List<_Chunk> _chunks(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final out = <_Chunk>[];
  var off = 8; // skip the file header
  while (off + 8 <= bytes.length) {
    final type = data.getUint16(off, Endian.little);
    final size = data.getInt32(off + 4, Endian.little);
    if (size < 8) break;
    out.add(_Chunk(type, off, size));
    off += size;
  }
  return out;
}

_Chunk? _chunk(Uint8List bytes, int type) {
  for (final c in _chunks(bytes)) {
    if (c.type == type) return c;
  }
  return null;
}

int _countChunks(Uint8List bytes, int type) => _chunks(bytes).where((c) => c.type == type).length;

List<String> _stringPool(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final chunk = _chunk(bytes, 0x0001);
  if (chunk == null) throw StateError('string pool not found');
  final headerSize = data.getUint16(chunk.offset + 2, Endian.little);
  final count = data.getInt32(chunk.offset + 8, Endian.little);
  final stringsStart = data.getInt32(chunk.offset + 20, Endian.little);
  final out = <String>[];
  for (var i = 0; i < count; i++) {
    var p = chunk.offset + stringsStart + data.getInt32(chunk.offset + headerSize + i * 4, Endian.little);
    final length = data.getUint16(p, Endian.little);
    p += 2;
    out.add(String.fromCharCodes([
      for (var k = 0; k < length; k++) data.getUint16(p + k * 2, Endian.little),
    ]));
  }
  return out;
}

List<int> _resourceMap(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final chunk = _chunk(bytes, 0x0180);
  if (chunk == null) throw StateError('resource map not found');
  final ids = <int>[];
  for (var off = chunk.offset + 8; off + 4 <= chunk.offset + chunk.size; off += 4) {
    ids.add(data.getInt32(off, Endian.little));
  }
  return ids;
}
