import 'dart:convert';
import 'dart:typed_data';

import 'package:arce_ai/ai/chatml_bridge.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/core/attachments.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List png([int extra = 0]) => Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(extra + 8, 1)]);
Uint8List jpeg() => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
Uint8List gif() => Uint8List.fromList([...ascii.encode('GIF89a'), 1, 2, 3]);
Uint8List webp() => Uint8List.fromList([...ascii.encode('RIFF'), 4, 0, 0, 0, ...ascii.encode('WEBP'), 1, 2]);
Uint8List text(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('ファイルの種類', () {
    test('先頭のバイトから、画像の種類を見分ける（名前は見ない）', () {
      expect(AttachmentReader.imageType(png()), 'image/png');
      expect(AttachmentReader.imageType(jpeg()), 'image/jpeg');
      expect(AttachmentReader.imageType(gif()), 'image/gif');
      expect(AttachmentReader.imageType(webp()), 'image/webp');
      expect(AttachmentReader.imageType(text('hello')), isNull);
      // RIFF だが WebP ではない（WAV など）
      expect(AttachmentReader.imageType(Uint8List.fromList([...ascii.encode('RIFF'), 4, 0, 0, 0, ...ascii.encode('WAVE')])), isNull);
      expect(AttachmentReader.imageType(Uint8List(0)), isNull);
    });

    test('画像に対応するモデルでは画像として読む', () {
      final a = AttachmentReader.read('photo.png', png(), acceptImages: true);
      expect(a.image?.mimeType, 'image/png');
      expect(a.text, isEmpty);
    });

    test('名前が .txt でも、中身が画像なら画像として読む', () {
      final a = AttachmentReader.read('renamed.txt', jpeg(), acceptImages: true);
      expect(a.image?.mimeType, 'image/jpeg');
    });

    test('画像に対応しないモデルでは、画像を理由つきで断る（文字化けをテキストとして渡さない）', () {
      expect(
        () => AttachmentReader.read('photo.png', png(), acceptImages: false),
        throwsA(isA<AttachmentException>().having((e) => e.message, 'message', contains('画像に対応していません'))),
      );
    });

    test('画像の大きさには上限がある', () {
      expect(
        () => AttachmentReader.read('big.png', png(AttachmentReader.maxImageBytes), acceptImages: true),
        throwsA(isA<AttachmentException>().having((e) => e.message, 'message', contains('大きすぎます'))),
      );
    });

    test('画像以外はテキストとして読む（対応モデルでも同じ）', () {
      for (final accept in [true, false]) {
        final a = AttachmentReader.read('notes.md', text('# 見出し\n本文'), acceptImages: accept);
        expect(a.text, '# 見出し\n本文');
        expect(a.image, isNull);
      }
    });

    test('SVG は画像ではなくテキストとして読む', () {
      final a = AttachmentReader.read('logo.svg', text('<svg xmlns="http://www.w3.org/2000/svg"/>'), acceptImages: true);
      expect(a.image, isNull);
      expect(a.text, startsWith('<svg'));
    });

    test('UTF-8 の BOM は取り除く', () {
      final a = AttachmentReader.read('bom.txt', Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('こんにちは')]), acceptImages: false);
      expect(a.text, 'こんにちは');
    });

    test('テキストでも画像でもないものは断る', () {
      final garbage = Uint8List.fromList([0x00, 0xFF, 0xFE, 0x80, 0x81]);
      expect(() => AttachmentReader.read('a.bin', garbage, acceptImages: true), throwsA(isA<AttachmentException>()));
      // 0 のバイトは UTF-8 としては正しいが、テキストファイルには無い
      expect(() => AttachmentReader.read('a.bin', Uint8List.fromList([0x41, 0x00, 0x42]), acceptImages: true), throwsA(isA<AttachmentException>()));
    });
  });

  group('プロンプトと画像の目印', () {
    test('画像は文字数の予算を使わず、目印として本文の前に入る', () {
      final image = AttachmentReader.read('a.png', png(), acceptImages: true);
      final composed = AttachmentPolicy.compose('これは何？', [image]);
      expect(composed, '${ImageMarker.of('a.png', image.image!)}\nこれは何？');
    });

    test('名前に目印を壊す文字があっても、目印は一つのまま読める', () {
      final image = ImageData('image/png', png());
      final marker = ImageMarker.of('a"/><b.png', image);
      final m = ImageMarker.pattern.allMatches(marker).single;
      expect(m.group(1), image.id);
    });

    test('同じ画像は同じ id になり、違う画像は違う id になる', () {
      expect(ImageData('image/png', png()).id, ImageData('image/png', png()).id);
      expect(ImageData('image/png', png()).id, isNot(ImageData('image/png', png(1)).id));
    });

    test('画像に対応するプロバイダでは、目印が画像になる', () {
      final image = AttachmentReader.read('a.png', png(), acceptImages: true);
      final prompt = ChatMlPromptBuilder.build([UserTurn(AttachmentPolicy.compose('これは何？', [image]))], const [], null, false);
      final messages = ChatMlBridge.messages(prompt, images: {image.image!.id: image.image!}, vision: true);
      final user = messages.firstWhere((m) => m.role == AiRole.user);
      expect(user.images.single.id, image.image!.id);
      expect(user.text, 'これは何？');
    });

    test('対応しないプロバイダでは、目印がファイル名の文字に変わる', () {
      final image = AttachmentReader.read('a.png', png(), acceptImages: true);
      final prompt = ChatMlPromptBuilder.build([UserTurn(AttachmentPolicy.compose('これは何？', [image]))], const [], null, false);
      final messages = ChatMlBridge.messages(prompt, images: {image.image!.id: image.image!});
      final user = messages.firstWhere((m) => m.role == AiRole.user);
      expect(user.images, isEmpty);
      expect(user.text, contains('[画像: a.png]'));
    });

    test('画像のバイトが残っていない（保存した会話を開いた後）ときも、ファイル名の文字になる', () {
      final image = AttachmentReader.read('a.png', png(), acceptImages: true);
      final prompt = ChatMlPromptBuilder.build([UserTurn(AttachmentPolicy.compose('続き', [image]))], const [], null, false);
      final messages = ChatMlBridge.messages(prompt, vision: true);
      final user = messages.firstWhere((m) => m.role == AiRole.user);
      expect(user.images, isEmpty);
      expect(user.text, contains('[画像: a.png]'));
    });
  });
}
