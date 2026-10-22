import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  })  : _client = client ?? http.Client(),
        _connections = connections ?? (() => 1);

  final Directory directory;
  final http.Client _client;

  /// Asked on every download, so a changed setting applies at once.
  final int Function() _connections;

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

  /// Downloads (or continues) [spec]. Throws on network errors and [DownloadCancelled] when the
  /// user stops it; the `.part` file stays so the download can resume.
  Future<File> download(
    ModelSpec spec,
    RemoteFile remote,
    void Function(int done, int total) onProgress,
    CancelToken cancel,
  ) async {
    await directory.create(recursive: true);
    final part = partial(spec);
    final start = await part.exists() ? await part.length() : 0;
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

  static Future<String> sha256Of(File file) async => (await sha256.bind(file.openRead()).first).toString();
}
