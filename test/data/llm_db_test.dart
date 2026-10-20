import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:arce_ai/data/legacy_import.dart';
import 'package:arce_ai/data/llm_db.dart';

void main() {
  late LlmDatabase db;

  setUp(() => db = LlmDatabase.memory());
  tearDown(() => db.close());

  String conversation({String title = '会話'}) => db.startConversation(
        title: title,
        agentId: 'general',
        providerId: 'local',
        modelId: 'qwen3.5-0.8b',
      );

  group('データベース', () {
    test('スキーマ版が記録される', () {
      expect(db.schemaVersion, 1);
    });

    test('同じパスを開き直してもデータが残る（永続化の確認）', () {
      final dir = Directory.systemTemp.createTempSync('arce_db_test');
      final path = '${dir.path}/arce_llm.db';

      final first = LlmDatabase.open(path);
      final id = first.startConversation(
        title: '残る会話',
        agentId: 'general',
        providerId: 'local',
        modelId: 'm',
      );
      first.addMessage(id, const NewMessage(MessageRole.user, [NewPart(PartKind.text, text: '本文')]));
      first.close();

      final second = LlmDatabase.open(path);
      final transcript = second.loadTranscript(id);
      expect(transcript!.messages.single.text, '本文');
      second.close();
      dir.deleteSync(recursive: true);
    });
  });

  group('会話', () {
    test('作成すると一覧に出る', () {
      final id = conversation(title: '最初の会話');
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')));

      final list = db.listConversations();
      expect(list, hasLength(1));
      expect(list.single.id, id);
      expect(list.single.title, '最初の会話');
      expect(list.single.providerId, 'local');
      expect(list.single.archived, isFalse);
    });

    test('更新の新しい順に並ぶ', () {
      final old = conversation(title: '古い');
      final recent = conversation(title: '新しい');
      db.setUpdatedAt(old, DateTime(2026, 1, 1));
      db.setUpdatedAt(recent, DateTime(2026, 10, 1));

      expect([for (final c in db.listConversations()) c.title], ['新しい', '古い']);
    });

    test('ピン留めは先頭に来る', () {
      final a = conversation(title: 'A');
      final b = conversation(title: 'B');
      db.setUpdatedAt(a, DateTime(2026, 1, 1));
      db.setUpdatedAt(b, DateTime(2026, 10, 1));
      db.setPinned(a, pinned: true);

      expect([for (final c in db.listConversations()) c.title], ['A', 'B']);
    });

    test('名前を変えると更新時刻も動く', () {
      final id = conversation();
      db.setUpdatedAt(id, DateTime(2026, 1, 1));
      db.renameConversation(id, '新しい名前');

      final row = db.conversation(id)!;
      expect(row.title, '新しい名前');
      expect(row.updatedAt, greaterThan(DateTime(2026, 1, 1).millisecondsSinceEpoch));
    });

    test('アーカイブすると既定の一覧から消える', () {
      final id = conversation();
      db.archiveConversation(id);

      expect(db.listConversations(), isEmpty);
      expect(db.listConversations(includeArchived: true), hasLength(1));

      db.archiveConversation(id, archived: false);
      expect(db.listConversations(), hasLength(1));
    });
  });

  group('メッセージ', () {
    test('seq は 0 から順に振られる', () {
      final id = conversation();
      db.addMessage(id, const NewMessage(MessageRole.user, [NewPart(PartKind.text, text: '一つ目')]));
      db.addMessage(id, const NewMessage(MessageRole.assistant, [NewPart(PartKind.text, text: '二つ目')]));
      db.addMessage(id, const NewMessage(MessageRole.user, [NewPart(PartKind.text, text: '三つ目')]));

      final rows = db.messagesOf(id);
      expect([for (final r in rows) r.seq], [0, 1, 2]);
      expect([for (final r in rows) r.role], ['user', 'assistant', 'user']);
    });

    test('パートは追加した順に読める', () {
      final id = conversation();
      final messageId = db.addMessage(
        id,
        const NewMessage(MessageRole.assistant, [
          NewPart(PartKind.reasoning, text: '考え中'),
          NewPart(PartKind.text, text: '答え'),
          NewPart(PartKind.toolResult, text: '2件', toolName: 'Search'),
        ]),
      );

      final transcript = db.loadTranscript(id)!;
      final parts = transcript.messages.single.parts;
      expect(parts.map((p) => p.kind), [PartKind.reasoning, PartKind.text, PartKind.toolResult]);
      expect(parts.map((p) => p.seq), [0, 1, 2]);
      expect(parts[1].body, '答え');
      expect(parts[2].toolName, 'Search');
      expect(transcript.messages.single.message.id, messageId);
      expect(transcript.messages.single.text, '答え');
    });

    test('メッセージを足すと会話の更新時刻が動く', () {
      final id = conversation();
      db.setUpdatedAt(id, DateTime(2026, 1, 1));

      db.addMessage(
        id,
        NewMessage(MessageRole.user, const [NewPart(PartKind.text, text: 'こんにちは')],
            createdAt: DateTime(2026, 3, 4, 5, 6)),
      );

      expect(db.conversation(id)!.updatedAt, DateTime(2026, 3, 4, 5, 6).millisecondsSinceEpoch);
    });

    test('返信の終わり方と使用量を記録できる', () {
      final id = conversation();
      final messageId = db.addMessage(
        id,
        const NewMessage(MessageRole.assistant, [NewPart(PartKind.text, text: '答え')]),
      );

      db.finishMessage(messageId,
          finishReason: 'stop', promptTokens: 120, completionTokens: 34, costMicros: 1500);

      final row = db.messagesOf(id).single;
      expect(row.finishReason, 'stop');
      expect(row.promptTokens, 120);
      expect(row.completionTokens, 34);
      expect(row.costMicros, 1500);
    });

    test('終わり方を二度書きしても他を消さない', () {
      final id = conversation();
      final messageId = db.addMessage(
        id,
        const NewMessage(MessageRole.assistant, [NewPart(PartKind.text, text: '答え')]),
      );
      db.finishMessage(messageId, promptTokens: 10);

      db.finishMessage(messageId, promptTokens: 20);

      final row = db.messagesOf(id).single;
      expect(row.promptTokens, 20);
      expect(row.completionTokens, isNull);
    });

    test('生成中の本文を差し替えられる', () {
      final id = conversation();
      final messageId = db.addMessage(
        id,
        const NewMessage(MessageRole.assistant, [NewPart(PartKind.text, text: 'こん')]),
      );

      db.updateStreamingText(messageId, 'こんにちは、世界');
      db.updateStreamingText(messageId, 'こんにちは、世界！');

      final parts = db.loadTranscript(id)!.messages.single.parts;
      expect(parts, hasLength(1));
      expect(parts.single.body, 'こんにちは、世界！');
    });

    test('存在しない会話は null', () {
      expect(db.loadTranscript('nope'), isNull);
    });
  });

  group('検索', () {
    test('日本語の途中一致で見つかる（trigram）', () {
      final id = conversation();
      db.addMessage(
        id,
        const NewMessage(MessageRole.user, [NewPart(PartKind.text, text: '今日の天気は晴れです')]),
      );

      final hits = db.search('天気は');
      expect(hits, hasLength(1));
      expect(hits.single.conversationId, id);
      expect(hits.single.snippet, contains('晴れ'));
    });

    test('3文字未満は LIKE で代替する', () {
      final id = conversation();
      db.addMessage(
        id,
        const NewMessage(MessageRole.user, [NewPart(PartKind.text, text: '今日の天気は晴れです')]),
      );

      expect(db.search('天気'), hasLength(1));
      expect(db.search('晴'), hasLength(1));
      expect(db.search('雪'), isEmpty);
    });

    test('LIKE のワイルドカードは文字として扱う', () {
      final a = conversation(title: 'A');
      final b = conversation(title: 'B');
      db.addMessage(a, const NewMessage(MessageRole.user, [NewPart(PartKind.text, text: '名前はa_bです')]));
      db.addMessage(b, const NewMessage(MessageRole.user, [NewPart(PartKind.text, text: '名前はaxbです')]));

      final hits = db.search('a_');
      expect(hits, hasLength(1));
      expect(hits.single.conversationId, a);
    });

    test('FTS の構文文字を含んでも落ちない', () {
      final id = conversation();
      db.addMessage(
        id,
        const NewMessage(MessageRole.user, [NewPart(PartKind.text, text: 'quote "test" and OR NEAR(x)')]),
      );

      expect(db.search('"test"'), isA<List<SearchHit>>());
      expect(db.search('OR'), isA<List<SearchHit>>());
      expect(db.search('NEAR(x)'), isA<List<SearchHit>>());
    });

    test('空の問い合わせは何も返さない', () {
      expect(db.search('   '), isEmpty);
    });

    test('削除した会話は検索に出ない', () {
      final id = conversation();
      db.addMessage(
        id,
        const NewMessage(MessageRole.user, [NewPart(PartKind.text, text: '消える予定の文章')]),
      );
      expect(db.search('消える予定'), hasLength(1));

      db.deleteConversation(id);
      expect(db.search('消える予定'), isEmpty);
    });

    test('会話ごとのメッセージ数を数えられる', () {
      final a = conversation(title: 'A');
      final b = conversation(title: 'B');
      db.addMessage(a, const NewMessage(MessageRole.user, [NewPart(PartKind.text, text: '1')]));
      db.addMessage(a, const NewMessage(MessageRole.assistant, [NewPart(PartKind.text, text: '2')]));
      db.addMessage(b, const NewMessage(MessageRole.user, [NewPart(PartKind.text, text: '3')]));

      expect(db.messageCounts(), {a: 2, b: 1});
    });
  });

  group('削除', () {
    test('メッセージとパートも一緒に消える', () {
      final id = conversation();
      final messageId = db.addMessage(
        id,
        const NewMessage(MessageRole.assistant, [
          NewPart(PartKind.reasoning, text: '考え'),
          NewPart(PartKind.text, text: '答え'),
        ]),
      );

      db.deleteConversation(id);

      expect(db.conversation(id), isNull);
      expect(db.messagesOf(id), isEmpty);
      expect(db.partsOf(messageId), isEmpty);
    });

    test('不要になった添付のパスを返す', () {
      final id = conversation();
      final assetId = db.addAsset(
        relPath: 'assets/$id/memo.txt',
        mime: 'text/plain',
        byteSize: 12,
        sha256: 'abc',
        conversationId: id,
      );
      expect(assetId, isNotEmpty);

      expect(db.deleteConversation(id), ['assets/$id/memo.txt']);
    });
  });

  group('添付', () {
    test('参照されている間は不要扱いにならない', () {
      final id = conversation();
      final assetId = db.addAsset(
        relPath: 'assets/a.png',
        mime: 'image/png',
        byteSize: 100,
        sha256: 'fff',
        conversationId: id,
      );
      db.addMessage(id, NewMessage(MessageRole.user, [NewPart(PartKind.image, assetId: assetId)]));

      expect(db.unreferencedAssets(), isEmpty);

      final other = db.addAsset(
        relPath: 'assets/b.png',
        mime: 'image/png',
        byteSize: 100,
        sha256: 'eee',
        conversationId: id,
      );
      expect([for (final a in db.unreferencedAssets()) a.id], [other]);
    });
  });

  group('旧JSONの取り込み', () {
    Map<String, Object?> legacy({int id = 1, bool generating = false}) => {
          'id': id,
          'title': '古い会話',
          'updatedAt': DateTime(2026, 5, 6, 7, 8).millisecondsSinceEpoch,
          'generating': generating,
          'snapshot': {
            'messages': [
              {
                'id': 0,
                'role': 'user',
                'text': 'こんにちは',
                'thinking': '',
                'question': null,
                'finish': null,
                'activities': <Object?>[],
                'agent': null,
                'attachments': ['memo.txt'],
                'time': DateTime(2026, 5, 6, 7, 0).millisecondsSinceEpoch,
              },
              {
                'id': 1,
                'role': 'assistant',
                'text': 'やあ',
                'thinking': '考え中',
                'question': {
                  'title': 'どれ？',
                  'options': ['A', 'B'],
                  'allowFreeInput': false,
                  'multiSelect': false,
                },
                'finish': 'stop',
                'activities': [
                  {
                    'tool': 'Search',
                    'summary': '1件',
                    'links': <Object?>[],
                    'failed': false,
                  },
                ],
                'agent': 'General Chat',
                'attachments': <Object?>[],
                'time': DateTime(2026, 5, 6, 7, 5).millisecondsSinceEpoch,
              },
            ],
            'history': <Object?>[],
            'nextId': 2,
          },
        };

    test('会話・メッセージ・パートが移る', () {
      expect(importLegacyConversation(db, legacy()), LegacyImportResult.imported);

      final row = db.conversation('legacy-1');
      expect(row, isNotNull);
      expect(row!.title, '古い会話');
      expect(row.providerId, 'local');
      expect(row.agentId, 'General Chat');
      expect(row.updatedAt, DateTime(2026, 5, 6, 7, 8).millisecondsSinceEpoch);
      expect(row.createdAt, DateTime(2026, 5, 6, 7, 0).millisecondsSinceEpoch);

      final transcript = db.loadTranscript('legacy-1')!;
      expect(transcript.messages, hasLength(2));
      expect([for (final m in transcript.messages) m.message.seq], [0, 1]);

      final user = transcript.messages.first.parts;
      expect(user.map((p) => p.kind), [PartKind.text, PartKind.attachment]);
      expect(user.last.body, 'memo.txt');

      final assistant = transcript.messages.last.parts;
      expect(assistant.map((p) => p.kind), [
        PartKind.reasoning,
        PartKind.text,
        PartKind.toolResult,
        PartKind.question,
      ]);
      expect(assistant[2].toolName, 'Search');
      expect(assistant[3].payload, contains('どれ？'));
      expect(transcript.messages.last.message.finishReason, 'stop');
    });

    test('二度取り込んでも増えない', () {
      expect(importLegacyConversation(db, legacy()), LegacyImportResult.imported);
      expect(importLegacyConversation(db, legacy()), LegacyImportResult.skipped);
      expect(db.listConversations(), hasLength(1));
    });

    test('生成中だった会話は続行できる状態で入る', () {
      importLegacyConversation(db, legacy(generating: true));
      expect(db.loadTranscript('legacy-1')!.messages.last.message.finishReason, 'cancelled');
    });

    test('壊れたファイルは failed として数え、他は続ける', () {
      final summary = importLegacyAll(db, [
        {'id': 'oops'},
        legacy(id: 2),
        legacy(id: 3),
      ]);
      expect(summary.failed, 1);
      expect(summary.imported, 2);
      expect(db.listConversations(), hasLength(2));
    });

    test('取り込んだ内容も検索できる', () {
      importLegacyConversation(db, legacy());
      expect(db.search('こんにちは'), hasLength(1));
    });

    test('取り込み済みの会話かどうかが分かる', () {
      expect(isLegacyConversation('legacy-12'), isTrue);
      expect(isLegacyConversation('0192ab'), isFalse);
    });
  });

  test('id は時系列で並ぶ', () {
    final early = newId(DateTime(2026, 1, 1));
    final late = newId(DateTime(2026, 6, 1));
    expect(early.compareTo(late), lessThan(0));
    expect({newId(), newId()}, hasLength(2));
  });
}
