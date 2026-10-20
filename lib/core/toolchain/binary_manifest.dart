import 'dart:typed_data';

/// Writes AndroidManifest.xml in Android's compiled binary XML format (the job aapt2 does when
/// it links an app), so a small app can be packaged on the phone without an aapt2 binary.
///
/// Only what a code-only app needs is supported: elements, the android namespace, and string,
/// integer and boolean attributes. Apps built this way carry no resources (layouts, images);
/// labels are plain strings and the system default icon is used.
///
/// Ported from the Kotlin version (`core/src/main/kotlin/ai/arce/core/toolchain/BinaryManifest.kt`).
class BinaryManifest {
  BinaryManifest._(this.root);

  final Element root;

  static const androidNamespace = 'http://schemas.android.com/apk/res/android';
  static const _androidPrefix = 'android';

  static const _stringPoolType = 0x0001;
  static const _xmlType = 0x0003;
  static const _startNamespaceType = 0x0100;
  static const _endNamespaceType = 0x0101;
  static const _startElementType = 0x0102;
  static const _endElementType = 0x0103;
  static const _resourceMapType = 0x0180;
  static const _typeString = 0x03;
  static const _typeIntDec = 0x10;
  static const _typeIntBoolean = 0x12;

  /// Framework attribute ids (android.R.attr) of the attributes this writer supports.
  static const androidAttrs = <String, int>{
    'label': 0x01010001,
    'icon': 0x01010002,
    'name': 0x01010003,
    'debuggable': 0x0101000f,
    'exported': 0x01010010,
    'minSdkVersion': 0x0101020c,
    'versionCode': 0x0101021b,
    'versionName': 0x0101021c,
    'targetSdkVersion': 0x01010270,
  };

  Uint8List toBytes() {
    // Attribute names that map to framework resource ids come first in the string pool,
    // in the same order as the resource map (that is how the parser resolves them).
    final all = <Element>[];
    _collect(root, all);
    final androidNames = <String>{};
    for (final e in all) {
      for (final a in e.attrs) {
        if (a.android) androidNames.add(a.name);
      }
    }
    final ordered = androidNames.toList()..sort((a, b) => androidAttrs[a]!.compareTo(androidAttrs[b]!));

    final strings = <String>{...ordered};
    strings.add(_androidPrefix);
    strings.add(androidNamespace);
    for (final e in all) {
      strings.add(e.name);
      for (final a in e.attrs) {
        strings.add(a.name);
        if (a.value is String) strings.add(a.value as String);
      }
    }
    final pool = strings.toList();
    final index = <String, int>{for (var i = 0; i < pool.length; i++) pool[i]: i};

    final body = BytesBuilder();
    body.add(_stringPool(pool));
    body.add(_resourceMap([for (final n in ordered) androidAttrs[n]!]));
    body.add(_namespace(_startNamespaceType, index[_androidPrefix]!, index[androidNamespace]!));
    _writeElement(root, index, body);
    body.add(_namespace(_endNamespaceType, index[_androidPrefix]!, index[androidNamespace]!));

    final bytes = body.takeBytes();
    return _le(8 + bytes.length, (w) {
      w.short(_xmlType);
      w.short(8);
      w.int32(8 + bytes.length);
      w.bytes(bytes);
    });
  }

  void _collect(Element e, List<Element> into) {
    into.add(e);
    for (final c in e.children) {
      _collect(c, into);
    }
  }

  void _writeElement(Element e, Map<String, int> index, BytesBuilder out) {
    final nsIndex = index[androidNamespace]!;
    // The framework looks attributes up by resource id; keep them sorted like aapt2 does.
    final attrs = e.attrs.toList()
      ..sort((a, b) {
        final byNs = (a.android ? 0 : 1).compareTo(b.android ? 0 : 1);
        if (byNs != 0) return byNs;
        final byId = (androidAttrs[a.name] ?? 0).compareTo(androidAttrs[b.name] ?? 0);
        return byId != 0 ? byId : a.name.compareTo(b.name);
      });
    final size = 16 + 20 + attrs.length * 20;
    out.add(_le(size, (w) {
      w.short(_startElementType);
      w.short(16);
      w.int32(size);
      w.int32(1);
      w.int32(-1); // line number, no comment
      w.int32(-1); // no namespace, element name
      w.int32(index[e.name]!);
      w.short(20);
      w.short(20);
      w.short(attrs.length);
      w.short(0);
      w.short(0);
      w.short(0); // id, class, style attribute indexes
      for (final a in attrs) {
        w.int32(a.android ? nsIndex : -1);
        w.int32(index[a.name]!);
        final v = a.value;
        if (v is String) {
          w.int32(index[v]!);
          w.typed(_typeString, index[v]!);
        } else if (v is int) {
          w.int32(-1);
          w.typed(_typeIntDec, v);
        } else {
          w.int32(-1);
          w.typed(_typeIntBoolean, (v as bool) ? -1 : 0);
        }
      }
    }));
    for (final c in e.children) {
      _writeElement(c, index, out);
    }
    out.add(_le(24, (w) {
      w.short(_endElementType);
      w.short(16);
      w.int32(24);
      w.int32(1);
      w.int32(-1);
      w.int32(-1);
      w.int32(index[e.name]!);
    }));
  }

  static Uint8List _le(int size, void Function(_LeWriter w) write) {
    final w = _LeWriter(size);
    write(w);
    return w.done;
  }

  /// UTF-16 string pool: each entry is a length, the characters, and a 0 terminator.
  static Uint8List _stringPool(List<String> strings) {
    final data = <int>[];
    final offsets = <int>[];
    for (final s in strings) {
      if (s.length >= 0x8000) throw ArgumentError('string too long');
      offsets.add(data.length);
      data.addAll(_le(2 + s.length * 2 + 2, (w) {
        w.short(s.length);
        for (final unit in s.codeUnits) {
          w.char(unit);
        }
        w.short(0);
      }));
    }
    while (data.length % 4 != 0) {
      data.add(0);
    }
    const header = 28;
    final stringsStart = header + strings.length * 4;
    final size = stringsStart + data.length;
    return _le(size, (w) {
      w.short(_stringPoolType);
      w.short(header);
      w.int32(size);
      w.int32(strings.length);
      w.int32(0);
      w.int32(0); // no styles, UTF-16
      w.int32(stringsStart);
      w.int32(0);
      for (final offset in offsets) {
        w.int32(offset);
      }
      w.bytes(data);
    });
  }

  static Uint8List _resourceMap(List<int> ids) {
    final size = 8 + ids.length * 4;
    return _le(size, (w) {
      w.short(_resourceMapType);
      w.short(8);
      w.int32(size);
      for (final id in ids) {
        w.int32(id);
      }
    });
  }

  static Uint8List _namespace(int type, int prefix, int uri) => _le(24, (w) {
        w.short(type);
        w.short(16);
        w.int32(24);
        w.int32(1);
        w.int32(-1);
        w.int32(prefix);
        w.int32(uri);
      });

  static BinaryManifest build(String rootName, void Function(Element e) block) {
    final root = Element(rootName);
    block(root);
    return BinaryManifest._(root);
  }

  /// A launcher app with one Activity, as the APK builder produces it.
  static BinaryManifest launcherApp({
    required String packageName,
    required String label,
    required String activityClass,
    required int minSdk,
    required int targetSdk,
    int versionCode = 1,
    String versionName = '1.0',
  }) =>
      build('manifest', (e) {
        e.attr('package', packageName);
        e.android('versionCode', versionCode);
        e.android('versionName', versionName);
        e.child('uses-sdk', (usesSdk) {
          usesSdk.android('minSdkVersion', minSdk);
          usesSdk.android('targetSdkVersion', targetSdk);
        });
        e.child('application', (application) {
          application.android('label', label);
          application.child('activity', (activity) {
            activity.android('name', activityClass);
            activity.android('label', label);
            activity.android('exported', true);
            activity.child('intent-filter', (filter) {
              filter.child('action', (action) => action.android('name', 'android.intent.action.MAIN'));
              filter.child('category', (category) => category.android('name', 'android.intent.category.LAUNCHER'));
            });
          });
        });
      });
}

/// One attribute of an element: a framework attribute ([android]) or a plain one.
class ManifestAttribute {
  const ManifestAttribute(this.android, this.name, this.value);
  final bool android;
  final String name;
  final Object value;
}

/// One element of the manifest tree, written with a builder-style API.
class Element {
  Element(this.name);

  final String name;
  final List<ManifestAttribute> attrs = [];
  final List<Element> children = [];

  Element attr(String name, String value) {
    attrs.add(ManifestAttribute(false, name, value));
    return this;
  }

  Element android(String name, Object value) {
    if (!BinaryManifest.androidAttrs.containsKey(name)) {
      throw ArgumentError('unknown android attribute: $name');
    }
    if (value is! String && value is! int && value is! bool) {
      throw ArgumentError('unsupported value for $name');
    }
    attrs.add(ManifestAttribute(true, name, value));
    return this;
  }

  Element child(String name, [void Function(Element e)? block]) {
    final e = Element(name);
    if (block != null) block(e);
    children.add(e);
    return this;
  }
}

/// Little-endian writer over a fixed-size buffer, mirroring the Kotlin `ByteBuffer` calls.
class _LeWriter {
  _LeWriter(this.size) : _data = ByteData(size);

  final int size;
  final ByteData _data;
  int _pos = 0;

  void short(int v) {
    _data.setInt16(_pos, v, Endian.little);
    _pos += 2;
  }

  void char(int v) {
    _data.setUint16(_pos, v, Endian.little);
    _pos += 2;
  }

  void int32(int v) {
    _data.setInt32(_pos, v, Endian.little);
    _pos += 4;
  }

  void byte(int v) {
    _data.setUint8(_pos, v);
    _pos += 1;
  }

  void bytes(List<int> v) {
    _data.buffer.asUint8List().setAll(_pos, v);
    _pos += v.length;
  }

  void typed(int type, int value) {
    short(8);
    byte(0);
    byte(type);
    int32(value);
  }

  Uint8List get done => _data.buffer.asUint8List();
}
