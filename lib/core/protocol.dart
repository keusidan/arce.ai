import 'dart:convert';

import 'app_settings_spec.dart';

/// A tool the model may call. [parameters] is a JSON Schema object; the same schema is shown
/// to the model in the system prompt and compiled to GBNF on the native side, so the two
/// cannot drift apart.
class ToolDefinition {
  const ToolDefinition({required this.name, required this.description, required this.parameters});

  final String name;
  final String description;
  final Map<String, Object?> parameters;
}

class QuestionTile {
  const QuestionTile({
    required this.title,
    required this.options,
    required this.allowFreeInput,
    required this.multiSelect,
  });

  static const maxOptions = 8;

  final String title;
  final List<String> options;
  final bool allowFreeInput;
  final bool multiSelect;

  Map<String, Object?> toJson() => {
        'title': title,
        'options': options,
        'allowFreeInput': allowFreeInput,
        'multiSelect': multiSelect,
      };

  factory QuestionTile.fromJson(Map<String, Object?> json) => QuestionTile(
        title: json['title'] as String,
        options: (json['options'] as List).cast<String>(),
        allowFreeInput: json['allowFreeInput'] as bool? ?? false,
        multiSelect: json['multiSelect'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is QuestionTile &&
      other.title == title &&
      _listEquals(other.options, options) &&
      other.allowFreeInput == allowFreeInput &&
      other.multiSelect == multiSelect;

  @override
  int get hashCode => Object.hash(title, Object.hashAll(options), allowFreeInput, multiSelect);
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

sealed class ToolCall {
  const ToolCall();
}

class AskUser extends ToolCall {
  const AskUser(this.tile);
  final QuestionTile tile;
}

class WebSearch extends ToolCall {
  const WebSearch(this.query);
  final String query;
}

class GetWeather extends ToolCall {
  const GetWeather(this.location);
  final String location;
}

class GetTime extends ToolCall {
  const GetTime(this.timezone);
  final String? timezone;
}

/// Reads every app setting (never the GitHub token).
class GetAppSettings extends ToolCall {
  const GetAppSettings();
}

/// A change the model proposes. It is applied only after the user approves it, and the chat, not
/// the tool runtime, does that (see [SettingsApproval]).
class SetAppSetting extends ToolCall {
  const SetAppSetting(this.change);
  final SettingChange change;
}

sealed class ParseResult {
  const ParseResult();
}

class ParseOk extends ParseResult {
  const ParseOk(this.call);
  final ToolCall call;
}

/// The grammar guarantees syntax, so this means the content itself is unusable.
class ParseInvalid extends ParseResult {
  const ParseInvalid(this.reason);
  final String reason;
}

abstract final class Protocol {
  /// Bumped whenever a tool schema changes. Stored with each generation so a regeneration
  /// can tell whether it runs under the same protocol as the original.
  static const schemaVersion = 3;

  static final askUser = ToolDefinition(
    name: 'ask_user',
    description: 'Ask the user a question and wait for the answer before continuing.',
    parameters: _objectSchema(required: ['title', 'options'], properties: {
      'title': {'type': 'string'},
      'options': {
        'type': 'array',
        'items': {'type': 'string'},
        'minItems': 1,
        'maxItems': QuestionTile.maxOptions,
      },
      'allow_free_input': {'type': 'boolean'},
      'multi_select': {'type': 'boolean'},
    }),
  );

  static final webSearch = ToolDefinition(
    name: 'web_search',
    description: 'Search the web. Use only when the answer needs current or external information.',
    parameters: _objectSchema(required: ['query'], properties: {
      'query': {'type': 'string'},
    }),
  );

  static final getWeather = ToolDefinition(
    name: 'get_weather',
    description: 'Get the current weather for a city or place name.',
    parameters: _objectSchema(required: ['location'], properties: {
      'location': {'type': 'string'},
    }),
  );

  static final getTime = ToolDefinition(
    name: 'get_time',
    description: 'Get the current date and time. timezone is an IANA name such as Asia/Tokyo; '
        'omit it for the device time zone.',
    parameters: _objectSchema(required: [], properties: {
      'timezone': {'type': 'string'},
    }),
  );

  static final getAppSettings = ToolDefinition(
    name: 'get_app_settings',
    description: 'Read every setting of this app (ARCE.AI) with its current value, label, allowed '
        'choices and range. Call this whenever the user asks about the app itself, its settings or '
        'its configuration, instead of guessing. The GitHub token is never returned.',
    parameters: _objectSchema(required: [], properties: {}),
  );

  static final setAppSetting = ToolDefinition(
    name: 'set_app_setting',
    description: 'Change one setting of this app. The user is asked to approve the change beforehand '
        'and it is applied only if they do, so say what you are about to change. Write value as a '
        'string: true/false for a switch, a number for a number, one of the choices otherwise. Read '
        'the current values with get_app_settings first. Keys: ${SettingsCatalog.keysForPrompt()}',
    parameters: _objectSchema(required: ['key', 'value'], properties: {
      'key': {'type': 'string'},
      'value': {'type': 'string'},
    }),
  );

  /// JSON Schema for the body of one `<tool_call>` block restricted to [tools]:
  /// `{"name": <one of the tools>, "arguments": <that tool's parameters>}`.
  /// Each agent passes only the tools it may use, so the grammar cannot express any other call.
  static Map<String, Object?> toolCallSchema(List<ToolDefinition> tools) {
    if (tools.isEmpty) {
      throw ArgumentError('an agent without tools needs no tool-call grammar');
    }
    return {
      'oneOf': [
        for (final tool in tools)
          {
            'type': 'object',
            'properties': {
              'name': {'const': tool.name},
              'arguments': tool.parameters,
            },
            'required': ['name', 'arguments'],
            'additionalProperties': false,
          },
      ],
    };
  }

  static Map<String, Object?> _objectSchema({
    required List<String> required,
    required Map<String, Object?> properties,
  }) =>
      {
        'type': 'object',
        'properties': properties,
        'required': required,
        'additionalProperties': false,
      };
}

/// What the user sees for [SetAppSetting]: the chat shows one card and changes nothing until the
/// user approves: the model may change the app's settings, but the user decides.
abstract final class SettingsApproval {
  static const approve = '承認';
  static const reject = '拒否';

  static QuestionTile tile(SettingChange change) => QuestionTile(
        title: '設定「${change.spec.label}」を ${change.display} に変更します。承認しますか？',
        options: const [approve, reject],
        allowFreeInput: false,
        multiSelect: false,
      );

  static bool isApproval(List<String> selected) => selected.contains(approve);
}

/// Turns the body of a `<tool_call>` block into a [ToolCall] and checks what the grammar
/// cannot: meaning. GBNF guarantees the JSON shape, not that option labels are non-blank
/// or distinct.
abstract final class ToolCallParser {
  static ParseResult parse(String body, List<ToolDefinition> allowed) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      return ParseInvalid('not JSON: ${e.message}');
    }
    if (decoded is! Map) return const ParseInvalid('not a JSON object');

    final name = decoded['name'];
    if (name is! String) return const ParseInvalid('missing tool name');
    if (allowed.every((t) => t.name != name)) return ParseInvalid("tool '$name' is not allowed here");
    final args = decoded['arguments'];
    if (args is! Map) return const ParseInvalid('missing arguments');

    try {
      if (name == Protocol.askUser.name) return _parseAskUser(args);
      if (name == Protocol.webSearch.name) {
        final q = _requiredText(args, 'query');
        return q == null ? const ParseInvalid('search query is blank') : ParseOk(WebSearch(q));
      }
      if (name == Protocol.getWeather.name) {
        final l = _requiredText(args, 'location');
        return l == null ? const ParseInvalid('weather location is blank') : ParseOk(GetWeather(l));
      }
      if (name == Protocol.getTime.name) return ParseOk(GetTime(_requiredText(args, 'timezone')));
      if (name == Protocol.getAppSettings.name) return ParseOk(const GetAppSettings());
      if (name == Protocol.setAppSetting.name) return _parseSetAppSetting(args);
      return ParseInvalid("tool '$name' has no handler");
    } on _WrongType catch (e) {
      return ParseInvalid('argument has the wrong type: ${e.key}');
    }
  }

  static String? _requiredText(Map<dynamic, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is Map || value is List) throw _WrongType(key);
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static bool _flag(Map<dynamic, dynamic> args, String key) {
    final value = args[key];
    if (value is bool) return value;
    if (value is String) return value == 'true';
    return false;
  }

  static ParseResult _parseSetAppSetting(Map<dynamic, dynamic> args) {
    final key = _requiredText(args, 'key');
    if (key == null) return const ParseInvalid('setting key is blank');
    final spec = SettingsCatalog.byKey(key);
    if (spec == null) return ParseInvalid("unknown setting '$key'");
    if (spec.readOnly) return ParseInvalid("'$key' is read-only");
    final raw = args['value'];
    if (raw is Map || raw is List) throw _WrongType('value');
    final change = SettingsCatalog.parse(key, raw?.toString() ?? '');
    if (change == null) return ParseInvalid("'${raw ?? ''}' is not an allowed value for $key");
    return ParseOk(SetAppSetting(change));
  }

  static ParseResult _parseAskUser(Map<dynamic, dynamic> args) {
    final title = _requiredText(args, 'title');
    if (title == null) return const ParseInvalid('question title is blank');

    final raw = args['options'];
    if (raw != null && raw is! List) throw _WrongType('options');
    final options = <String>[
      for (final o in (raw as List?) ?? const [])
        if (o is Map || o is List) throw _WrongType('options') else (o?.toString().trim() ?? ''),
    ];
    if (options.isEmpty) return const ParseInvalid('question has no options');
    if (options.length > QuestionTile.maxOptions) return const ParseInvalid('too many options');
    if (options.any((o) => o.isEmpty)) return const ParseInvalid('an option is blank');
    if (options.toSet().length != options.length) return const ParseInvalid('options are not distinct');

    return ParseOk(AskUser(QuestionTile(
      title: title,
      options: options,
      allowFreeInput: _flag(args, 'allow_free_input'),
      multiSelect: _flag(args, 'multi_select'),
    )));
  }
}

class _WrongType implements Exception {
  _WrongType(this.key);
  final String key;
}
