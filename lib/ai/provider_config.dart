import 'dart:convert';

/// One model of a provider, with the sampling settings and the extra prompt it needs.
///
/// A provider usually offers many models, and each one may want a different temperature or a
/// different system prompt. Keeping them together means switching model is one tap, and the
/// per-model settings travel with the model instead of being typed again.
class ModelConfig {
  const ModelConfig({
    required this.id,
    required this.name,
    this.params = const {},
    this.prompt = '',
  });

  /// The name the API expects (`gpt-4o-mini`, `openai/gpt-oss-120b`, ...).
  final String id;

  /// What the settings screen shows; the id itself when the user did not name it.
  final String name;

  /// Overrides for the request body: `temperature`, `topP`, `maxTokens` and any other number the
  /// provider understands. Empty means the app's own value is used.
  final Map<String, double> params;

  /// Added as a system message in front of every request for this model.
  final String prompt;

  double? param(String key) => params[key];

  int? intParam(String key) {
    final value = params[key];
    return value == null ? null : value.round();
  }

  ModelConfig copyWith({
    String? name,
    Map<String, double>? params,
    String? prompt,
  }) => ModelConfig(
    id: id,
    name: name ?? this.name,
    params: params ?? this.params,
    prompt: prompt ?? this.prompt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (params.isNotEmpty) 'params': params,
    if (prompt.trim().isNotEmpty) 'prompt': prompt,
  };

  factory ModelConfig.fromJson(Map<String, Object?> json) {
    final id = json['id'] is String ? json['id']! as String : '';
    final rawParams = json['params'];
    return ModelConfig(
      id: id,
      name:
          json['name'] is String && (json['name']! as String).trim().isNotEmpty
          ? json['name']! as String
          : id,
      params: {
        if (rawParams is Map)
          for (final entry in rawParams.entries)
            if (entry.key is String && entry.value is num)
              entry.key as String: (entry.value! as num).toDouble(),
      },
      prompt: json['prompt'] is String ? json['prompt']! as String : '',
    );
  }
}

/// A provider the user added: where to send the request and which models it offers.
///
/// The API key is deliberately not a field. Keys live in the platform's secure storage under
/// [keyRef], so a settings file, a backup or a QR export never carries one.
class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.label,
    required this.baseUrl,
    this.models = const [],
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

  /// The models this provider offers. Never empty once the provider is usable.
  final List<ModelConfig> models;

  /// Extra request headers and body fields, for services that differ from the OpenAI schema.
  final Map<String, String> headers;
  final Map<String, Object?> body;

  /// Whether the endpoint offers function calling.
  final bool supportsTools;

  /// Where the key for this provider is kept in the secure storage.
  String get keyRef => 'provider_key.$id';

  /// The first model, used when nothing else is selected.
  ModelConfig? get defaultModel => models.isEmpty ? null : models.first;

  ModelConfig? modelById(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// The id of the first model, or an empty string; kept for the database column.
  String get model => defaultModel?.id ?? '';

  /// True when everything a request needs is set.
  bool get isComplete =>
      id.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      models.isNotEmpty &&
      (Uri.tryParse(baseUrl.trim())?.hasScheme ?? false);

  ProviderConfig copyWith({
    String? label,
    String? baseUrl,
    List<ModelConfig>? models,
    Map<String, String>? headers,
    Map<String, Object?>? body,
    bool? supportsTools,
  }) => ProviderConfig(
    id: id,
    label: label ?? this.label,
    baseUrl: baseUrl ?? this.baseUrl,
    models: models ?? this.models,
    headers: headers ?? this.headers,
    body: body ?? this.body,
    supportsTools: supportsTools ?? this.supportsTools,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'baseUrl': baseUrl,
    'models': [for (final model in models) model.toJson()],
    if (headers.isNotEmpty) 'headers': headers,
    if (body.isNotEmpty) 'body': body,
    if (!supportsTools) 'tools': false,
  };

  /// Anything missing or wrongly typed falls back to a usable default, so an older or a damaged
  /// save still loads. [ProviderList.decode] drops what cannot be used at all.
  factory ProviderConfig.fromJson(Map<String, Object?> json) {
    String text(String key) => json[key] is String ? json[key]! as String : '';
    final rawHeaders = json['headers'];
    final rawModels = json['models'];
    final models = <ModelConfig>[
      if (rawModels is List)
        for (final entry in rawModels)
          if (entry is Map) ModelConfig.fromJson(entry.cast<String, Object?>()),
    ];
    // a save from before models existed keeps its one model, so nothing is lost on upgrade
    final legacy = text('model');
    final effective = models.where((m) => m.id.trim().isNotEmpty).toList();
    if (effective.isEmpty && legacy.trim().isNotEmpty) {
      effective.add(ModelConfig(id: legacy, name: legacy));
    }
    return ProviderConfig(
      id: text('id'),
      label: text('label'),
      baseUrl: text('baseUrl'),
      models: effective,
      headers: {
        if (rawHeaders is Map)
          for (final entry in rawHeaders.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
      },
      body: json['body'] is Map
          ? (json['body']! as Map).cast<String, Object?>()
          : const {},
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
        if (config.id.trim().isEmpty ||
            config.id == localId ||
            config.baseUrl.trim().isEmpty)
          continue;
        out.add(config);
      }
      return out;
    } catch (_) {
      // a damaged list must not stop the app; the user can add the providers again
      return const [];
    }
  }

  static String encode(List<ProviderConfig> providers) =>
      jsonEncode([for (final p in providers) p.toJson()]);

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
