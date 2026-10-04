import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/releases.dart';
import 'desktop_installer.dart';
import 'settings.dart';

sealed class UpdateState {
  const UpdateState();
}

class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

class UpdateUpToDate extends UpdateState {
  const UpdateUpToDate();
}

class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.release);
  final Release release;
}

class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.release, this.done, this.total);
  final Release release;
  final int done;
  final int total;
}

class UpdateReady extends UpdateState {
  const UpdateReady(this.release, this.file);
  final Release release;
  final File file;
}

class UpdateFailed extends UpdateState {
  const UpdateFailed(this.reason);
  final String reason;
}

/// Updates from the GitHub releases of the repository: check, then download only after the
/// user approves, verify the published SHA-256, and install the build for this platform.
///
/// Android installs through PackageInstaller (the APK must carry the same signature as the
/// installed app). Windows, macOS and Linux replace their own files and restart. iOS cannot
/// install outside the App Store, so it opens the release page.
class UpdateService extends ChangeNotifier {
  UpdateService(
    this._settings, {
    http.Client? client,
    Future<Directory> Function()? cacheDirectory,
    this.currentVersion,
  })  : _client = client ?? http.Client(),
        _cacheDirectory = cacheDirectory ?? getApplicationCacheDirectory;

  static const _system = MethodChannel('ai.arce.app/system');

  final SettingsStore _settings;
  final http.Client _client;
  final Future<Directory> Function() _cacheDirectory;

  UpdateState _state = const UpdateIdle();
  UpdateState get state => _state;

  Version? currentVersion;
  Timer? _timer;

  /// The release found by the last successful check; [download] works from it.
  Release? _release;

  static UpdateTarget? get target {
    if (kIsWeb) return null;
    if (Platform.isAndroid) return UpdateTarget.android;
    if (Platform.isIOS) return UpdateTarget.ios;
    if (Platform.isWindows) return UpdateTarget.windows;
    if (Platform.isMacOS) return UpdateTarget.macos;
    if (Platform.isLinux) return UpdateTarget.linux;
    return null;
  }

  Future<void> init() async {
    if (currentVersion == null) {
      final info = await PackageInfo.fromPlatform();
      currentVersion = Version.parse(info.version);
    }
    notifyListeners();
    _schedule();
    _settings.addListener(_schedule);
    if (_settings.value.autoUpdateCheck) unawaited(check(silent: true));
  }

  void _schedule() {
    _timer?.cancel();
    final s = _settings.value;
    if (!s.autoUpdateCheck) return;
    _timer = Timer.periodic(Duration(hours: s.updateIntervalHours.clamp(1, 168)), (_) => check(silent: true));
  }

  void _set(UpdateState state) {
    _state = state;
    notifyListeners();
  }

  bool isNewer(Release release) => currentVersion == null || release.version > currentVersion!;

  /// [silent] keeps quiet when there is nothing new or the check fails (automatic checks).
  Future<void> check({bool silent = false}) async {
    if (_state is UpdateChecking || _state is UpdateDownloading) return;
    if (!silent) _set(const UpdateChecking());
    try {
      final release = await latest();
      if (isNewer(release)) {
        _release = release;
        _set(UpdateAvailable(release));
      } else if (!silent) {
        _set(const UpdateUpToDate());
      }
    } catch (e) {
      if (!silent) _set(UpdateFailed(_explain(e)));
    }
  }

  /// The newest release made for this platform. Every platform has its own releases, so the list is read
  /// instead of "latest" (which is whichever platform was published last).
  Future<Release> latest() async {
    final platform = target;
    if (platform == null) throw StateError('このOSには更新ファイルがありません');
    final repo = _settings.value.updateRepo;
    final response = await _client
        .get(
          Uri.parse('https://api.github.com/repos/$repo/releases?per_page=50'),
          headers: _headers('application/vnd.github+json', withToken: true),
        )
        .timeout(const Duration(seconds: 20));
    switch (response.statusCode) {
      case 200:
        return ReleaseParser.latestFor(response.body, platform) ??
            (throw StateError('この端末（${platform.name}）向けのリリースがまだありません'));
      case 401 || 403:
        throw StateError('GitHub がトークンを受け付けませんでした（HTTP ${response.statusCode}）。設定のトークンを確認してください');
      case 404:
        throw StateError('リリースが見つかりません（HTTP 404）。非公開リポジトリには Contents: read のトークンが必要です');
      default:
        throw StateError('GitHub HTTP ${response.statusCode}');
    }
  }

  String _explain(Object e) => e is StateError ? e.message : e.toString();

  Map<String, String> _headers(String accept, {required bool withToken}) => {
        'Accept': accept,
        'User-Agent': 'ARCE.AI/${currentVersion ?? '0'}',
        'X-GitHub-Api-Version': '2022-11-28',
        if (withToken && _settings.githubToken.isNotEmpty) 'Authorization': 'Bearer ${_settings.githubToken}',
      };

  /// Downloads the asset for this platform and checks it against the release's `.sha256` asset.
  Future<void> download() async {
    final release = _release;
    if (release == null || _state is UpdateDownloading) return;
    final t = target;
    final asset = t == null ? null : release.assetFor(t);
    if (asset == null) {
      _set(UpdateFailed('${release.tag} にこの端末向けのビルドがありません'));
      return;
    }
    if (t == UpdateTarget.ios) {
      await openReleasePage(release);
      return;
    }
    final checksum = release.checksumFor(asset);
    if (checksum == null) {
      _set(UpdateFailed('${release.tag} に ${asset.name}.sha256 がありません'));
      return;
    }
    _set(UpdateDownloading(release, 0, asset.sizeBytes));
    try {
      final expected = ReleaseParser.parseChecksum(utf8Text(await _assetBytes(checksum)));
      if (expected == null) throw StateError('チェックサムファイルを読み取れません');
      final cache = await _cacheDirectory();
      final dir = Directory('${cache.path}${Platform.pathSeparator}updates');
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}${asset.name}');
      final digest = await _downloadAsset(asset, file, (done) => _set(UpdateDownloading(release, done, asset.sizeBytes)));
      if (digest.toLowerCase() != expected.toLowerCase()) {
        await file.delete();
        throw StateError('SHA-256 が一致しません。ダウンロードを破棄しました');
      }
      _set(UpdateReady(release, file));
    } catch (e) {
      _set(UpdateFailed(_explain(e)));
    }
  }

  static String utf8Text(List<int> bytes) => String.fromCharCodes(bytes);

  /// Asset downloads answer with a redirect to signed storage. The GitHub token must not be
  /// sent there (the storage rejects a second credential), so the redirect is followed by hand.
  Future<http.StreamedResponse> _openAsset(ReleaseAsset asset) async {
    final repo = _settings.value.updateRepo;
    final api = http.Request('GET', Uri.parse('https://api.github.com/repos/$repo/releases/assets/${asset.id}'))
      ..followRedirects = false
      ..headers.addAll(_headers('application/octet-stream', withToken: true));
    final first = await _client.send(api).timeout(const Duration(seconds: 30));
    if (first.statusCode >= 300 && first.statusCode < 400) {
      final location = first.headers['location'];
      await first.stream.drain<void>();
      if (location == null) throw StateError('リダイレクト先がありません');
      final storage = http.Request('GET', Uri.parse(location))..headers.addAll(_headers('application/octet-stream', withToken: false));
      final second = await _client.send(storage).timeout(const Duration(seconds: 30));
      if (second.statusCode < 200 || second.statusCode > 299) {
        throw StateError('ダウンロードに失敗しました（HTTP ${second.statusCode}）');
      }
      return second;
    }
    if (first.statusCode < 200 || first.statusCode > 299) {
      throw StateError('ダウンロードに失敗しました（HTTP ${first.statusCode}）');
    }
    return first;
  }

  Future<List<int>> _assetBytes(ReleaseAsset asset) async {
    final response = await _openAsset(asset);
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  /// Streams the asset into [file] and returns its SHA-256 (hex).
  Future<String> _downloadAsset(ReleaseAsset asset, File file, void Function(int done) onProgress) async {
    final response = await _openAsset(asset);
    final sink = file.openWrite();
    final hash = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(hash);
    var done = 0;
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        input.add(chunk);
        done += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastReport) > const Duration(milliseconds: 200)) {
          lastReport = now;
          onProgress(done);
        }
      }
    } finally {
      await sink.close();
    }
    input.close();
    return hash.events.single.toString();
  }

  Future<bool> canInstall() async {
    if (!Platform.isAndroid) return true;
    return await _system.invokeMethod<bool>('canInstall') ?? false;
  }

  /// Opens the system screen where the user allows ARCE.AI to install apps (first time only).
  Future<void> requestInstallPermission() => _system.invokeMethod<void>('requestInstall');

  Future<void> install() async {
    final current = _state;
    if (current is! UpdateReady) return;
    try {
      if (Platform.isAndroid) {
        await _system.invokeMethod<void>('install', {'path': current.file.path});
      } else {
        await DesktopInstaller.apply(current.file);
      }
    } catch (e) {
      _set(UpdateFailed(_explain(e)));
    }
  }

  Future<void> openReleasePage(Release release) async {
    final url = release.htmlUrl ?? 'https://github.com/${_settings.value.updateRepo}/releases/tag/${release.tag}';
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void dismiss() => _set(const UpdateIdle());

  @override
  void dispose() {
    _timer?.cancel();
    _settings.removeListener(_schedule);
    super.dispose();
  }
}

/// Collects the single digest produced by a chunked conversion.
class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];

  @override
  void add(T data) => events.add(data);

  @override
  void close() {}
}
