import 'dart:convert';
import 'dart:io';

import 'package:arce_ai/core/releases.dart';
import 'package:arce_ai/services/settings.dart';
import 'package:arce_ai/services/update_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The name the release workflow gives the asset of this platform,
/// e.g. `ARCE.AI-v0.5.0-linux-x64.tar.gz`.
String assetName() => 'ARCE.AI-v0.5.0-${UpdateService.target?.suffix.substring(1) ?? 'linux-x64.tar.gz'}';

/// A GitHub that serves one release, and a storage that honours a range request, ignores it, or
/// stops in the middle of the stream (as a dropped connection does).
class FakeGitHub {
  FakeGitHub({
    required this.payload,
    required this.checksum,
    this.honourRange = true,
    this.cutOff = false,
  });

  final List<int> payload;
  final String checksum;

  /// Answer a range request with `206` and the rest of the file.
  final bool honourRange;

  /// Stop the stream halfway through.
  final bool cutOff;

  /// Every `Range` header the storage received, in order.
  final List<String?> ranges = [];

  MockClient client() => MockClient.streaming((request, body) async {
        final url = request.url.toString();
        http.StreamedResponse reply(int code, Stream<List<int>> bytes, [Map<String, String> headers = const {}]) =>
            http.StreamedResponse(bytes, code, headers: headers, request: request);

        if (url.contains('/releases?')) {
          final prefix = UpdateService.target?.tagPrefix ?? '';
          return reply(
            200,
            Stream.value(utf8.encode(jsonEncode([
              {
                'tag_name': '${prefix}v0.5.0',
                'body': '',
                'assets': [
                  {'id': 11, 'name': assetName(), 'size': payload.length},
                  {'id': 12, 'name': '${assetName()}.sha256', 'size': 90},
                ],
              },
            ]))),
          );
        }
        if (url.contains('/releases/assets/')) {
          return reply(302, const Stream.empty(), {'location': 'https://storage.example/${url.split('/').last}'});
        }
        if (url.startsWith('https://storage.example/')) {
          if (url.endsWith('/12')) return reply(200, Stream.value(utf8.encode('$checksum  ${assetName()}\n')));

          final range = request.headers['Range'];
          ranges.add(range);
          if (!honourRange || range == null) {
            return cutOff ? reply(200, _halfThenBreak()) : reply(200, Stream.value(payload));
          }
          final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          return cutOff ? reply(206, _halfThenBreak(from)) : reply(206, Stream.value(payload.sublist(from)));
        }
        return reply(404, const Stream.empty());
      });

  Stream<List<int>> _halfThenBreak([int from = 0]) async* {
    final rest = payload.sublist(from);
    yield rest.sublist(0, rest.length ~/ 2);
    throw const SocketException('connection lost');
  }
}

Future<(UpdateService, Directory)> serviceFor(MockClient client, {String current = '0.4.0'}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsStore(await SharedPreferences.getInstance());
  await settings.setGithubToken('secret');
  final dir = await Directory.systemTemp.createTemp('arce_update_resume');
  addTearDown(() => dir.delete(recursive: true));
  final service = UpdateService(
    settings,
    client: client,
    cacheDirectory: () async => dir,
    currentVersion: Version.parse(current),
  );
  addTearDown(service.dispose);
  return (service, dir);
}

void main() {
  // large enough that the part file is written in more than one chunk
  final payload = List<int>.generate(40000, (i) => i % 256);
  final good = sha256.convert(payload).toString();
  final canDownload = UpdateService.target != null && UpdateService.target != UpdateTarget.ios;

  Directory updates(Directory root) => Directory('${root.path}${Platform.pathSeparator}updates');

  File partFile(Directory root) =>
      File('${updates(root).path}${Platform.pathSeparator}${assetName()}.part');

  test('ダウンロードが途中で切れても、途中までのファイルを残す', () async {
    final github = FakeGitHub(payload: payload, checksum: good, cutOff: true);
    final (service, dir) = await serviceFor(github.client());

    await service.check();
    await service.download();

    expect(service.state, isA<UpdateFailed>());
    expect(await partFile(dir).exists(), isTrue, reason: 'the next attempt resumes from here');
    final kept = await partFile(dir).length();
    expect(kept, greaterThan(0));
    expect(kept, lessThan(payload.length));
  }, skip: canDownload ? false : 'this platform has no update files');

  test('残っていた分は Range で続きだけを取り、全体の SHA-256 で検証する', () async {
    final github = FakeGitHub(payload: payload, checksum: good);
    final (service, dir) = await serviceFor(github.client());
    await updates(dir).create(recursive: true);
    await partFile(dir).writeAsBytes(payload.sublist(0, 10000));

    await service.check();
    await service.download();

    final ready = service.state as UpdateReady;
    expect(await ready.file.readAsBytes(), payload);
    expect(github.ranges, ['bytes=10000-'], reason: 'only the rest is asked for');
    expect(await partFile(dir).exists(), isFalse, reason: 'the part file becomes the real one');
  }, skip: canDownload ? false : 'this platform has no update files');

  test('サーバーが Range を無視したら、最初から取り直す', () async {
    final github = FakeGitHub(payload: payload, checksum: good, honourRange: false);
    final (service, dir) = await serviceFor(github.client());
    await updates(dir).create(recursive: true);
    await partFile(dir).writeAsBytes(payload.sublist(0, 10000));

    await service.check();
    await service.download();

    final ready = service.state as UpdateReady;
    expect(await ready.file.readAsBytes(), payload, reason: 'the partial bytes must not be kept twice');
    expect(github.ranges, ['bytes=10000-', null]);
  }, skip: canDownload ? false : 'this platform has no update files');

  test('壊れた途中ファイルは捨てて取り直す', () async {
    final github = FakeGitHub(payload: payload, checksum: good);
    final (service, dir) = await serviceFor(github.client());
    await updates(dir).create(recursive: true);
    // longer than the asset, so it cannot be a prefix of this file
    await partFile(dir).writeAsBytes(List.filled(payload.length + 100, 7));

    await service.check();
    await service.download();

    final ready = service.state as UpdateReady;
    expect(await ready.file.readAsBytes(), payload);
    expect(github.ranges, [null], reason: 'it is a fresh download, not a range request');
  }, skip: canDownload ? false : 'this platform has no update files');

  test('更新後は、いま動いている版のダウンロードを消す', () async {
    final (service, dir) = await serviceFor(
      FakeGitHub(payload: payload, checksum: good).client(),
      current: '0.4.0',
    );
    await updates(dir).create(recursive: true);
    final old = File('${updates(dir).path}${Platform.pathSeparator}ARCE.AI-v0.3.0-old.apk');
    final installed = File('${updates(dir).path}${Platform.pathSeparator}ARCE.AI-v0.4.0-current.apk');
    final next = File('${updates(dir).path}${Platform.pathSeparator}ARCE.AI-v0.5.0-next.apk.part');
    for (final f in [old, installed, next]) {
      await f.writeAsBytes(const [1, 2, 3]);
    }

    await service.removeOldDownloads();

    expect(await old.exists(), isFalse);
    expect(await installed.exists(), isFalse, reason: 'this version is the one now running');
    expect(await next.exists(), isTrue, reason: 'a download that can still be resumed is kept');
  });
}
