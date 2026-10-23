import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../core/model_catalog.dart';
import 'segmented_download.dart';

class RemoteFile {
  const RemoteFile({required this.sizeBytes, this.sha256});
  final int sizeBytes;
  final String? sha256;
}

/// Lets the user stop a download; the partial file is kept for Resume.
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

/// Downloads a model file from Hugging Face into the model directory.
/// - resumes a `.part` file with an HTTP Range request, but only when the user presses Resume
/// - verifies the SHA-256 that Hugging Face publishes for LFS files before installing
class ModelDownloader {
  ModelDownloader(
    this.directory, {
    http.Client? client,
    int Function()? connections,
    this.stall,
    int Function()? attempts,
    this.retryDelay = const Duration(seconds: 2),
  })  : _client = client ?? http.Client(),
        _connections = connections ?? (() => 1),
        _attempts = attempts ?? (() => 1);

  final Directory directory;
  final http.Client _client;

  /// Asked on every download, so a changed setting applies at once.
  final int Function() _connections;

  /// How many times a download is tried before it is reported as failed (asked on every download);
  /// every try after the first continues from what is already on disk. The wait before try *n* is
  /// `retryDelay * n`.
  final int Function() _attempts;
  final Duration retryDelay;

  /// How long a connection may stay silent, asked on every download; null waits for ever.
  final Duration Function()? stall;

  File target(ModelSpec spec) => File('${directory.path}${Platform.pathSeparator}${spec.fileName}');
  File partial(ModelSpec spec) => File('${target(spec).path}.part');

  /// Bytes of [spec] already on disk: the partial file, or the parts of a download over several connections.
  Future<int> downloadedBytes(ModelSpec spec) async {
    final part = partial(spec);
    final single = await part.exists() ? await part.length() : 0;
    return single > 0 ? single : await SegmentedDownload.storedBytes(part);
  }

  /// Size and checksum from the Hugging Face tree API.
  Future<RemoteFile> remote(ModelSpec spec) async {
    final response = await _client
        .get(Uri.parse('https://huggingface.co/api/models/${spec.hfRepo}/tree/main'), headers: _headers)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
    final entries = jsonDecode(response.body) as List;
    final entry = entries.cast<Map>().firstWhere(
          (e) => e['path'] == spec.fileName,
          orElse: () => throw StateError('${spec.fileName} not found in ${spec.hfRepo}'),
        );
    final lfs = entry['lfs'] as Map?;
    return RemoteFile(
      sizeBytes: ((lfs?['size'] ?? entry['size']) as num?)?.toInt() ?? spec.fileBytes,
      sha256: lfs?['oid'] as String?,
    );
  }

  /// A failure of the connection itself (or a server that is busy), as opposed to an answer that
  /// trying again cannot change. Only these are tried again.
  static bool isTransient(Object e) {
    if (e is SocketException || e is TimeoutException || e is http.ClientException || e is TlsException) return true;
    if (e is HttpException) {
      final status = int.tryParse(RegExp(r'HTTP (\d+)').firstMatch(e.message)?.group(1) ?? '');
      return status != null && (status >= 500 || status == 429);
    }
    return false;
  }

  /// What the screen shows for a failed download. The text of the exceptions of the HTTP client
  /// carries the whole address, and that of a CDN is a signed link several hundred characters long.
  static String explainError(Object e) {
    if (e is http.ClientException && e.message.toLowerCase().contains('connection closed')) {
      return '通信が途切れました（サーバーが接続を閉じました）。「再開」で続きから取ります';
    }
    if (e is TimeoutException) return '応答がありません。「再開」で続きから取ります';
    if (e is SocketException) return '通信できません: ${e.osError?.message ?? e.message}';
    final text = '$e'.replaceAll(RegExp(r',? ?uri=\S+'), '').replaceAll(RegExp(r'https?://\S+'), '（URL）');
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  /// Downloads (or continues) [spec], trying again after a failure of the connection. Throws the
  /// last error, and [DownloadCancelled] when the user stops it; the part files stay so the download
  /// can resume.
  Future<File> download(
    ModelSpec spec,
    RemoteFile remote,
    void Function(int done, int total) onProgress,
    CancelToken cancel,
  ) async {
    final attempts = _attempts().clamp(1, 20);
    for (var attempt = 1;; attempt++) {
      try {
        return await _downloadOnce(spec, remote, onProgress, cancel);
      } on DownloadCancelled {
        rethrow;
      } catch (e) {
        if (!isTransient(e) || attempt >= attempts) rethrow;
        await Future<void>.delayed(retryDelay * attempt);
        if (cancel.isCancelled) throw const DownloadCancelled();
      }
    }
  }

  Future<File> _downloadOnce(
    ModelSpec spec,
    RemoteFile remote,
    void Function(int done, int total) onProgress,
    CancelToken cancel,
  ) async {
    await directory.create(recursive: true);
    final part = partial(spec);
    var start = await part.exists() ? await part.length() : 0;
    // A file as long as the model is the whole of it (the app stopped before it was checked): asking
    // for the rest would be answered with 416. One that is longer cannot be a part of it.
    if (start == remote.sizeBytes) return part;
    if (start > remote.sizeBytes) {
      await part.delete();
      start = 0;
    }
    final url = Uri.parse('https://huggingface.co/${spec.hfRepo}/resolve/main/${spec.fileName}');

    // A fresh (or segmented) download uses several connections; a partial file from one connection
    // is finished the way it was started.
    if (start == 0 && SegmentedDownload.parts(remote.sizeBytes, _connections()) >= 2) {
      final joined = await SegmentedDownload.run(
        part: part,
        total: remote.sizeBytes,
        connections: _connections(),
        open: (from, to) => _client
            .send(http.Request('GET', url)..headers.addAll({..._headers, 'Range': 'bytes=$from-$to'}))
            .timeout(const Duration(seconds: 30)),
        onProgress: (done) => onProgress(done, remote.sizeBytes),
        cancelled: () => cancel.isCancelled,
        stall: stall?.call(),
      );
      if (joined) return part;
    }

    final request = http.Request('GET', url)..headers.addAll(_headers);
    if (start > 0) request.headers['Range'] = 'bytes=$start-';
    final response = await _client.send(request).timeout(const Duration(seconds: 30));
    if (response.statusCode == 416 && start > 0) {
      // the part file does not belong to this file any more: start again from the beginning
      await response.stream.drain<void>().catchError((_) {});
      await part.delete();
      return _downloadOnce(spec, remote, onProgress, cancel);
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    final resumed = response.statusCode == 206;
    var done = resumed ? start : 0;
    final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in response.stream) {
        if (cancel.isCancelled) throw const DownloadCancelled();
        sink.add(chunk);
        done += chunk.length;
        onProgress(done, remote.sizeBytes);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return part;
  }

  /// Checks the SHA-256 and moves the file into place; deletes it when corrupt.
  Future<File> install(ModelSpec spec, RemoteFile remote, File part) async {
    final expected = remote.sha256;
    if (expected != null) {
      final actual = await sha256Of(part);
      if (actual.toLowerCase() != expected.toLowerCase()) {
        await part.delete();
        throw StateError('SHA-256 mismatch (file corrupted); downloaded file removed');
      }
    }
    return part.rename(target(spec).path);
  }

  /// Integrity check of an installed model (spec §19 整合性確認).
  Future<bool> verify(ModelSpec spec, RemoteFile remote) async {
    final file = target(spec);
    if (!await file.exists() || await file.length() != remote.sizeBytes) return false;
    final expected = remote.sha256;
    return expected == null || (await sha256Of(file)).toLowerCase() == expected.toLowerCase();
  }

  static Map<String, String> get _headers => const {'User-Agent': 'ARCE.AI'};

  /// The SHA-256 of [file], worked out in another isolate: a model is gigabytes, and the screen
  /// must keep moving meanwhile.
  static Future<String> sha256Of(File file) {
    final path = file.path;
    return Isolate.run(() async => (await sha256.bind(File(path).openRead()).first).toString());
  }
}
