import 'dart:convert';

/// Semantic version "1.2.3" with an optional "-suffix"; a suffix sorts before the plain release.
class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch, [this.suffix = '']);

  final int major;
  final int minor;
  final int patch;
  final String suffix;

  static final _pattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:[-.+](.+))?$');

  static Version? parse(String text) {
    final m = _pattern.firstMatch(text.trim());
    if (m == null) return null;
    return Version(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!), m.group(4) ?? '');
  }

  @override
  int compareTo(Version other) {
    final byNumber = [major.compareTo(other.major), minor.compareTo(other.minor), patch.compareTo(other.patch)]
        .firstWhere((c) => c != 0, orElse: () => 0);
    if (byNumber != 0) return byNumber;
    if (suffix.isEmpty && other.suffix.isEmpty) return 0;
    if (suffix.isEmpty) return 1;
    if (other.suffix.isEmpty) return -1;
    return suffix.compareTo(other.suffix);
  }

  bool operator >(Version other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, suffix);

  @override
  String toString() => '$major.$minor.$patch${suffix.isEmpty ? '' : '-$suffix'}';
}

class ReleaseAsset {
  const ReleaseAsset({required this.id, required this.name, required this.sizeBytes});
  final int id;
  final String name;
  final int sizeBytes;
}

/// The platform builds a release can carry. [suffix] is what the release workflow appends to the file name.
enum UpdateTarget {
  android('-android.apk'),
  ios('-ios-unsigned.ipa'),
  windows('-windows-x64.zip'),
  macos('-macos.zip'),
  linux('-linux-x64.tar.gz');

  const UpdateTarget(this.suffix);
  final String suffix;
}

class Release {
  const Release({required this.tag, required this.version, required this.notes, required this.assets, this.htmlUrl});

  final String tag;
  final Version version;
  final String notes;
  final List<ReleaseAsset> assets;
  final String? htmlUrl;

  ReleaseAsset? assetFor(UpdateTarget target) {
    for (final a in assets) {
      if (a.name.endsWith(target.suffix)) return a;
    }
    return null;
  }

  /// The `<asset>.sha256` file written next to every build by the release workflow.
  ReleaseAsset? checksumFor(ReleaseAsset asset) {
    for (final a in assets) {
      if (a.name == '${asset.name}.sha256') return a;
    }
    return null;
  }
}

abstract final class ReleaseParser {
  /// Parses GitHub's "get the latest release" response.
  static Release? parse(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final tag = decoded['tag_name'];
    if (tag is! String) return null;
    final version = Version.parse(tag);
    if (version == null) return null;
    final assets = <ReleaseAsset>[
      for (final a in (decoded['assets'] as List? ?? const []))
        if (a is Map && a['id'] is int && a['name'] is String)
          ReleaseAsset(id: a['id'] as int, name: a['name'] as String, sizeBytes: (a['size'] as num?)?.toInt() ?? 0),
    ];
    return Release(
      tag: tag,
      version: version,
      notes: decoded['body'] as String? ?? '',
      assets: assets,
      htmlUrl: decoded['html_url'] as String?,
    );
  }

  /// `<hex>  file.apk` as written by sha256sum.
  static String? parseChecksum(String text) {
    final first = text.trim().split(RegExp(r'\s+')).first;
    return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(first) ? first : null;
  }
}
