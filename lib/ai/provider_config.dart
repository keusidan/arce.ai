import 'dart:convert';

/// A provider the user added: where to send the request and what to call the model.
///
/// The API key is deliberately not a field. Keys live in the platform's secure storage under
/// [keyRef], so a settings file, a backup or a QR export never carries one.
class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.model,
    this.headers = const {},
    this.body = const {},
    this.supportsTools = true,
  });

  /// Stable id, also stored in the database (`conversations.provider_id`).
  final String id;

  /// What the settings screen and the chat header show.
  final String label;

  /// Everything before `/chat/completions`, e.g. `https://api.openai.com/v1`.
  final String baseUrl;
  final String model;

  /// Extra request headers and body fields, for services that differ from the OpenAI schema.
  final Map<String, String> headers;
  final Map<String, Object?> body;

  /// Whether the endpoint offers function calling.
  final bool supportsTools;

  /// Where the key for this provider is kept in the secure storage.
  String get keyRef => 'provider_key.$id';

  /// True when everything a request needs is set.
  bool get isComplete =>
      id.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty &&
      (Uri.tryParse(baseUrl.trim())?.hasScheme ?? false);

  ProviderConfig copyWith({
    String? label,
    String? baseUrl,
    String? model,
    Map<String, String>? headers,
    Map<String, Object?>? body,
    bool? supportsTools,
  }) =>
      ProviderConfig(
        id: id,
        label: label ?? this.label,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        headers: headers ?? this.headers,
        body: body ?? this.body,
        supportsTools: supportsTools ?? this.supportsTools,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'baseUrl': baseUrl,
        'model': model,
        if (headers.isNotEmpty) 'headers': headers,
        if (body.isNotEmpty) 'body': body,
        if (!supportsTools) 'tools': false,
      };

  /// Anything missing or wrongly typed falls back to a usable default, so an older or a damaged
  /// save still loads. [ProviderList.decode] drops what cannot be used at all.
  factory ProviderConfig.fromJson(Map<String, Object?> json) {
    String text(String key) => json[key] is String ? json[key]! as String : '';
    final rawHeaders = json['headers'];
    return ProviderConfig(
      id: text('id'),
      label: text('label'),
      baseUrl: text('baseUrl'),
      model: text('model'),
      headers: {
        if (rawHeaders is Map)
          for (final entry in rawHeaders.entries)
            if (entry.key is String && entry.value is String) entry.key as String: entry.value as String,
      },
      body: json['body'] is Map ? (json['body']! as Map).cast<String, Object?>() : const {},
      supportsTools: json['tools'] is bool ? json['tools']! as bool : true,
    );
  }
}

/// The provider list as one JSON document, the way the settings store keeps it.
abstract final class ProviderList {
  /// The on-device model: a provider like any other, and never an implicit fallback.
  static const localId = 'local';

  static List<ProviderConfig> decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <ProviderConfig>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final config = ProviderConfig.fromJson(entry.cast<String, Object?>());
        // an id of its own, and a base URL: without either the entry cannot be used or saved
        if (config.id.trim().isEmpty || config.id == localId || config.baseUrl.trim().isEmpty) continue;
        out.add(config);
      }
      return out;
    } catch (_) {
      // a damaged list must not stop the app; the user can add the providers again
      return const [];
    }
  }

  static String encode(List<ProviderConfig> providers) => jsonEncode([for (final p in providers) p.toJson()]);

  /// A new id from the label, so the id is readable in the database; a suffix keeps it unique.
  static String idFor(String label, Iterable<ProviderConfig> existing) {
    final stem = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = stem.isEmpty ? 'provider' : stem;
    final taken = {for (final p in existing) p.id}..add(localId);
    if (!taken.contains(base)) return base;
    for (var n = 2; ; n++) {
      final candidate = '$base-$n';
      if (!taken.contains(candidate)) return candidate;
    }
  }
}
