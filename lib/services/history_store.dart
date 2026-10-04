import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/chat_controller.dart';

class ConversationMeta {
  const ConversationMeta({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.messageCount,
    required this.generating,
  });

  final int id;
  final String title;
  final DateTime updatedAt;
  final int messageCount;

  /// A generation was still running when the app last stopped (spec §25.1).
  final bool generating;
}

/// Conversations as one JSON file each, so a damaged file loses one chat and not all of them.
class HistoryStore {
  HistoryStore(this.directory);

  final Directory directory;

  static Future<HistoryStore> open({Directory? supportDirectory}) async {
    final support = supportDirectory ?? await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}conversations');
    await dir.create(recursive: true);
    return HistoryStore(dir);
  }

  File _file(int id) => File('${directory.path}${Platform.pathSeparator}$id.json');

  Future<List<ConversationMeta>> list() async {
    final metas = <ConversationMeta>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await entity.readAsString()) as Map;
        final snapshot = json['snapshot'] as Map;
        metas.add(ConversationMeta(
          id: json['id'] as int,
          title: json['title'] as String,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int),
          messageCount: (snapshot['messages'] as List).length,
          generating: json['generating'] as bool? ?? false,
        ));
      } catch (_) {
        // skip a damaged file
      }
    }
    metas.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return metas;
  }

  /// Saves under [id], or under a new id when it is null; returns the id used.
  Future<int> save(int? id, ConversationSnapshot snapshot, {required bool generating}) async {
    final newId = id ?? DateTime.now().microsecondsSinceEpoch;
    final first = snapshot.messages.where((m) => m.role == Role.user).firstOrNull?.text.trim() ?? '';
    final title = first.isEmpty ? '新しい会話' : (first.length > 40 ? first.substring(0, 40) : first);
    final body = jsonEncode({
      'id': newId,
      'title': title,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'generating': generating,
      'snapshot': snapshot.toJson(),
    });
    // write to a temporary file first so a crash never leaves a half-written conversation
    final temp = File('${_file(newId).path}.tmp');
    await temp.writeAsString(body, flush: true);
    await temp.rename(_file(newId).path);
    return newId;
  }

  Future<ConversationSnapshot?> get(int id) async {
    try {
      final json = jsonDecode(await _file(id).readAsString()) as Map;
      return ConversationSnapshot.fromJson((json['snapshot'] as Map).cast());
    } catch (_) {
      return null;
    }
  }

  Future<void> delete(int id) async {
    final file = _file(id);
    if (await file.exists()) await file.delete();
  }

  Future<void> clearGenerating(int id) async {
    final snapshot = await get(id);
    if (snapshot != null) await save(id, snapshot, generating: false);
  }
}
