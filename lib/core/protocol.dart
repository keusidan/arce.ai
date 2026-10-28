import 'dart:convert';

import 'settings_spec.dart';

/// A tool the model may call. [parameters] is a JSON Schema object; the same schema is shown
/// to the model in the system prompt and compiled to GBNF on the native side, so the two
/// cannot drift apart.
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });

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
  int get hashCode =>
      Object.hash(title, Object.hashAll(options), allowFreeInput, multiSelect);
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

/// Reads the settings the model may change, with their current values (never API keys).
class GetSettings extends ToolCall {
  const GetSettings();
}

class GetTime extends ToolCall {
  const GetTime(this.timezone);
  final String? timezone;
}

/// A proposed change to the app's own settings. Nothing is applied until the user approves it;
/// the chat shows the list and asks.
class UpdateSettings extends ToolCall {
  const UpdateSettings(this.changes);
  final List<SettingsChangeOk> changes;
}

/// A proposed new provider. Nothing is saved until the user approves it; the API key is never part
/// of it (the user types it on the settings screen).
class AddProvider extends ToolCall {
  const AddProvider(this.draft);
  final ProviderDraft draft;
}

/// One job the planner model gives to the developer model.
class DelegateTask {
  const DelegateTask({required this.title, required this.instructions, this.files = const [], this.revise});

  final String title;

  /// Complete and specific: the developer sees nothing else but this and the summary.
  final String instructions;

  /// The files this task writes, when the planner named them.
  final List<String> files;

  /// The id of an earlier result (`d3`) that this job corrects: [instructions] is then what to change
  /// in it, and the developer is given its own earlier answer again.
  final String? revise;
}

/// The coding mode: the planner model hands jobs to the developer model. The app only carries them
/// out (all at the same time, up to the limit) and returns what came back; what to split, whether
/// the result is good and whether to send work back are the planner's own decisions.
class Delegate extends ToolCall {
  const Delegate({required this.summary, required this.tasks});

  /// What every task shares: the decisions, names and interfaces the tasks must agree on.
  final String summary;
  final List<DelegateTask> tasks;
}

/// A tool that comes from an MCP server. [arguments] is exactly what the server was sent.
class McpCall extends ToolCall {
  const McpCall(this.name, this.arguments);

  final String name;
  final Map<String, Object?> arguments;
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
  static const schemaVersion = 5;

  static final askUser = ToolDefinition(
    name: 'ask_user',
    description:
        'Ask the user a question and wait for the answer before continuing.',
    parameters: _objectSchema(
      required: ['title', 'options'],
      properties: {
        'title': {'type': 'string'},
        'options': {
          'type': 'array',
          'items': {'type': 'string'},
          'minItems': 1,
          'maxItems': QuestionTile.maxOptions,
        },
        'allow_free_input': {'type': 'boolean'},
        'multi_select': {'type': 'boolean'},
      },
    ),
  );

  static final webSearch = ToolDefinition(
    name: 'web_search',
    description: 'Search the web. Use only when the answer needs current or external information.',
    parameters: _objectSchema(
      required: ['query'],
      properties: {
        'query': {'type': 'string'},
      },
    ),
  );

  static final getWeather = ToolDefinition(
    name: 'get_weather',
    description: 'Get the current weather for a city or place name.',
    parameters: _objectSchema(
      required: ['location'],
      properties: {
        'location': {'type': 'string'},
      },
    ),
  );

  static final getTime = ToolDefinition(
    name: 'get_time',
    description:
        'Get the current date and time. timezone is an IANA name such as Asia/Tokyo; '
        'omit it for the device time zone.',
    parameters: _objectSchema(
      required: [],
      properties: {
        'timezone': {'type': 'string'},
      },
    ),
  );

  static final getSettings = ToolDefinition(
    name: 'get_settings',
    description:
        'Read the app settings the model may change, with their current values, labels, '
        "allowed choices and ranges, plus the configured providers, their models and the MCP "
        'servers (name, URL, whether enabled, which tools). A new provider is added with add_provider; '
        'existing providers and the MCP servers are edited on the settings screen. This tool reports '
        'them so you can answer questions about them instead of guessing. API keys, MCP tokens and the '
        'update source are never returned.',
    parameters: _objectSchema(required: [], properties: {}),
  );

  static final updateSettings = ToolDefinition(
    name: 'update_settings',
    description:
        'Change the app settings (thinking, search, tone, theme, model options, ...). '
        'Each change is shown to the user and applied only if they approve it. '
        'Providers and MCP servers are not settings of this kind: add a provider with add_provider, '
        'and edit existing ones on the settings screen; read them with get_settings. There is '
        'deliberately no way to read or write API keys or MCP tokens, and the update source cannot '
        'be changed either.',
    parameters: _objectSchema(
      required: ['changes'],
      properties: {
        'changes': {
          'type': 'array',
          'minItems': 1,
          'maxItems': AgentSettings.maxChanges,
          'items': {
            'type': 'object',
            'properties': {
              'key': {'type': 'string', 'enum': AgentSettings.keys},
              'value': {
                'oneOf': [
                  {'type': 'boolean'},
                  {'type': 'number'},
                  {'type': 'string'},
                ],
              },
            },
            'required': ['key', 'value'],
            'additionalProperties': false,
          },
        },
      },
    ),
  );

  static final addProvider = ToolDefinition(
    name: 'add_provider',
    description:
        'Add a new online provider with an OpenAI-compatible API (base_url is everything before '
        '/chat/completions, e.g. https://api.example.com/v1). The user is shown the name, address '
        'and models and the provider is saved only if they approve. It cannot change a provider '
        'that already exists, and it has no field for an API key: after it is added, tell the user to '
        'open the settings screen, choose the provider and type the API key there.',
    parameters: _objectSchema(
      required: ['name', 'base_url', 'models'],
      properties: {
        'name': {'type': 'string'},
        'base_url': {'type': 'string'},
        'models': {
          'type': 'array',
          'items': {'type': 'string'},
          'minItems': 1,
          'maxItems': ProviderDraft.maxModels,
        },
        'tools': {'type': 'boolean'},
      },
    ),
  );

  /// Most tasks one `delegate` call may carry (the grammar's limit; the setting can be lower).
  static const maxDelegateTasks = 8;

  static final delegate = ToolDefinition(
    name: 'delegate',
    description:
        'Coding mode: hand jobs to the developer model, which writes the code. The jobs run at the same '
        'time and cannot see each other, so put the names, signatures and data formats they must agree '
        'on in summary and in every job that touches them. Each job must be complete: the developer sees '
        'nothing else. You get each result back with an id. The user sees the developer\'s files as they '
        'come, so do not copy them into your answer; read them, and if something is wrong call delegate '
        'again with revise (the id of that result) and exactly what to change.',
    parameters: _objectSchema(
      required: ['tasks'],
      properties: {
        'summary': {'type': 'string'},
        'tasks': {
          'type': 'array',
          'minItems': 1,
          'maxItems': maxDelegateTasks,
          'items': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'instructions': {'type': 'string'},
              'files': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'revise': {'type': 'string'},
            },
            'required': ['title', 'instructions'],
            'additionalProperties': false,
          },
        },
      },
    ),
  );

  // ---------------------------------------------------------------- the app's own tools

  /// The app's own shell tool: one command in the Linux environment on the device (docs 15 and
  /// 19.5). It is parsed as an [McpCall] and run by the MCP runtime, which is where the chat looks
  /// for calls it cannot run itself.
  static const runCommandName = 'run_command';

  static final runCommand = ToolDefinition(
    name: runCommandName,
    description:
        'Run one shell command in the Linux environment (Ubuntu 24.04, arm64) that lives inside this '
        'app, in the root file system under proot. It is a pseudo root, not a sandbox, and there is no '
        'systemd. /workspace is shared by every chat and kept between them (up to 2048 MB); HOME is '
        '/workspace/home. apt, pip (use --user) and git work, and there is no switch for the network. '
        'Commands run one at a time and cannot ask for input. The output is cut when it is long, and '
        'the command is stopped when it runs longer than timeout_seconds or when it fills the '
        'workspace. The first command installs the environment (about 30 MB, a few minutes) if the '
        'user has not done it yet; the user approves every command first.',
    parameters: _objectSchema(
      required: ['command'],
      properties: {
        'command': {'type': 'string'},
        'cwd': {'type': 'string'},
        'timeout_seconds': {'type': 'integer'},
      },
    ),
  );

  /// GitHub Actions, read only: what the CI of a branch did, and which steps of one run failed.
  /// The GitHub MCP server the app talks to offers no Actions tools, so this reads the REST API.
  static const ciStatusName = 'ci_status';

  static final ciStatus = ToolDefinition(
    name: ciStatusName,
    description:
        'Read GitHub Actions of a repository (the app\'s own unless repository says otherwise), '
        'read only. Without run_id it lists the newest runs of a branch (all branches when branch '
        'is omitted); with run_id it lists the jobs of that run, with the steps that failed. Use it '
        'to say whether a push is green on every platform, instead of asking the user to copy a log.',
    parameters: _objectSchema(
      required: [],
      properties: {
        'repository': {'type': 'string'},
        'branch': {'type': 'string'},
        'limit': {'type': 'integer'},
        'run_id': {'type': 'integer'},
      },
    ),
  );

  /// The tools that parse as an [McpCall]: the MCP servers' own, and the app's own two above.
  static bool isMcpLike(String name) =>
      name.startsWith('mcp_') || name == runCommandName || name == ciStatusName;

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
  }) => {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
}

/// The card the chat shows for [UpdateSettings]: nothing is written until the user approves.
abstract final class SettingsApproval {
  static const approve = '承認';
  static const reject = '拒否';

  static QuestionTile tile(List<SettingsChangeOk> changes) => QuestionTile(
    title: '設定を変更します。${changes.map((c) => c.description).join('、')}。承認しますか？',
    options: const [approve, reject],
    allowFreeInput: false,
    multiSelect: false,
  );

  static bool isApproval(List<String> selected) => selected.contains(approve);
}

/// The card the chat shows for [AddProvider]: nothing is saved until the user approves.
abstract final class ProviderApproval {
  static const approve = '追加する';
  static const reject = 'やめる';

  static QuestionTile tile(ProviderDraft draft) => QuestionTile(
    title: '${draft.description}。追加しますか？（APIキーは追加後に設定画面で入力します）',
    options: const [approve, reject],
    allowFreeInput: false,
    multiSelect: false,
  );

  static bool isApproval(List<String> selected) => selected.contains(approve);
}

/// The card the chat shows for an [McpCall] that changes something outside the device, and for
/// every `run_command` (a command can do anything the app itself can).
abstract final class ToolApproval {
  static const approve = '実行する';
  static const reject = 'やめる';

  static QuestionTile tile(McpCall call) => QuestionTile(
    title: _title(call),
    options: const [approve, reject],
    allowFreeInput: false,
    multiSelect: false,
  );

  /// A command is shown as it is (`$ command`), with where and for how long: the model's words
  /// about it are not what the user approves. Everything else keeps the name and the arguments.
  static String _title(McpCall call) {
    if (call.name == Protocol.runCommandName) {
      final command = '${call.arguments['command'] ?? ''}'.trim();
      final cwd = '${call.arguments['cwd'] ?? '/workspace'}'.trim();
      final seconds = call.arguments['timeout_seconds'];
      final limit = seconds is num ? '・最大 ${seconds.toInt()} 秒' : '';
      return 'このコマンドを実行します。\n\$ $command\n場所: $cwd$limit';
    }
    return 'この道具を実行します。${call.name}\n'
        '${call.arguments.isEmpty ? '' : call.arguments.toString()}';
  }

  static bool isApproval(List<String> selected) => selected.contains(approve);

  /// The words of a tool name that mean it changes something outside the device (create, delete,
  /// submit, start ...). A tool name is read word by word, whatever its style (`create_or_update_file`,
  /// `CreateBenchmarkTaskFromPrompt`): `ListDatasets` is a read although "datasets" contains "set".
  static const writeVerbs = {
    'create', 'update', 'delete', 'remove', 'push', 'merge', 'commit', 'write', 'edit', 'close', 'reopen',
    'add', 'set', 'put', 'patch', 'fork', 'transfer', 'review', 'submit', 'start', 'cancel', 'stop', 'run',
    'rerun', 'upload', 'publish', 'save', 'post', 'send', 'apply', 'execute', 'trigger', 'enable', 'disable',
    'approve', 'assign', 'import', 'insert', 'rename', 'move', 'replace', 'restore', 'revert', 'invite',
    'grant', 'kill',
  };

  /// Their names come from the server (`mcp_<server>__<tool>`); the server's own id is not read.
  static bool needsApproval(String name) {
    final at = name.lastIndexOf('__');
    final tool = at >= 0 ? name.substring(at + 2) : name;
    final words = RegExp(r'[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+').allMatches(tool).map((m) => m.group(0)!.toLowerCase());
    return words.any(writeVerbs.contains);
  }
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
      // the start of the text is shown too: "Unexpected character" alone does not say what came
      final preview = body.length > 120 ? '${body.substring(0, 120)}…' : body;
      return ParseInvalid('not JSON: ${e.message.split('\n').first} ($preview)');
    }
    if (decoded is! Map) return const ParseInvalid('not a JSON object');

    final name = decoded['name'];
    if (name is! String) return const ParseInvalid('missing tool name');
    if (allowed.every((t) => t.name != name)) {
      return ParseInvalid("tool '$name' is not allowed here");
    }
    final args = decoded['arguments'];
    if (args is! Map) return const ParseInvalid('missing arguments');

    try {
      if (name == Protocol.askUser.name) return _parseAskUser(args);
      if (name == Protocol.webSearch.name) {
        final q = _requiredText(args, 'query');
        return q == null
            ? const ParseInvalid('search query is blank')
            : ParseOk(WebSearch(q));
      }
      if (name == Protocol.getWeather.name) {
        final l = _requiredText(args, 'location');
        return l == null
            ? const ParseInvalid('weather location is blank')
            : ParseOk(GetWeather(l));
      }
      if (name == Protocol.getTime.name) {
        return ParseOk(GetTime(_requiredText(args, 'timezone')));
      }
      if (name == Protocol.getSettings.name) {
        return ParseOk(const GetSettings());
      }
      if (name == Protocol.updateSettings.name) {
        return _parseUpdateSettings(args);
      }
      if (name == Protocol.addProvider.name) {
        return _parseAddProvider(args);
      }
      if (name == Protocol.delegate.name) {
        return _parseDelegate(args);
      }
      if (name == Protocol.ciStatusName) return _parseCiStatus(args);
      // a tool of an MCP server, or the app's own run_command: the engine's schema already limited
      // it to the tools this turn allows
      if (Protocol.isMcpLike(name)) {
        if (name == Protocol.runCommandName) return _parseRunCommand(args);
        return ParseOk(McpCall(name, args.cast<String, Object?>()));
      }
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

  static ParseResult _parseAskUser(Map<dynamic, dynamic> args) {
    final title = _requiredText(args, 'title');
    if (title == null) return const ParseInvalid('question title is blank');

    final raw = args['options'];
    if (raw != null && raw is! List) throw _WrongType('options');
    final options = <String>[
      for (final o in (raw as List?) ?? const [])
        if (o is Map || o is List)
          throw _WrongType('options')
        else
          (o?.toString().trim() ?? ''),
    ];
    if (options.isEmpty) return const ParseInvalid('question has no options');
    if (options.length > QuestionTile.maxOptions) {
      return const ParseInvalid('too many options');
    }
    if (options.any((o) => o.isEmpty)) {
      return const ParseInvalid('an option is blank');
    }
    if (options.toSet().length != options.length) {
      return const ParseInvalid('options are not distinct');
    }

    return ParseOk(
      AskUser(
        QuestionTile(
          title: title,
          options: options,
          allowFreeInput: _flag(args, 'allow_free_input'),
          multiSelect: _flag(args, 'multi_select'),
        ),
      ),
    );
  }

  /// The command is the one thing that matters: a blank one is refused, and the rest is passed on
  /// as it came (the runner bounds the time and the output).
  static ParseResult _parseRunCommand(Map<dynamic, dynamic> args) {
    final command = _requiredText(args, 'command');
    if (command == null) return const ParseInvalid('the command is blank');
    final cwd = _requiredText(args, 'cwd');
    if (cwd != null && !cwd.startsWith('/')) {
      return const ParseInvalid('cwd must be an absolute path inside the environment');
    }
    final timeout = args['timeout_seconds'];
    if (timeout != null && timeout is! num) throw _WrongType('timeout_seconds');
    return ParseOk(
      McpCall(Protocol.runCommandName, {
        'command': command,
        if (cwd != null) 'cwd': cwd,
        if (timeout is num) 'timeout_seconds': timeout.toInt(),
      }),
    );
  }

  /// A repository is `owner/name` (or none, for the app's own), the branch and the run are as they
  /// came: reading the runs is all this does.
  static ParseResult _parseCiStatus(Map<dynamic, dynamic> args) {
    final repository = _requiredText(args, 'repository');
    if (repository != null && !RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      return const ParseInvalid('repository must look like owner/name');
    }
    final branch = _requiredText(args, 'branch');
    final limit = args['limit'];
    if (limit != null && limit is! num) throw _WrongType('limit');
    final runId = args['run_id'];
    if (runId != null && runId is! num) throw _WrongType('run_id');
    final arguments = <String, Object?>{};
    if (repository != null) arguments['repository'] = repository;
    if (branch != null) arguments['branch'] = branch;
    if (limit is num) arguments['limit'] = limit.toInt();
    if (runId is num) arguments['run_id'] = runId.toInt();
    return ParseOk(McpCall(Protocol.ciStatusName, arguments));
  }

  static ParseResult _parseDelegate(Map<dynamic, dynamic> args) {
    final raw = args['tasks'];
    if (raw is! List) throw _WrongType('tasks');
    final tasks = <DelegateTask>[];
    for (final item in raw) {
      if (item is! Map) throw _WrongType('tasks');
      final instructions = _requiredText(item, 'instructions');
      if (instructions == null) return const ParseInvalid('a task has no instructions');
      final files = item['files'];
      tasks.add(
        DelegateTask(
          title: _requiredText(item, 'title') ?? 'タスク ${tasks.length + 1}',
          instructions: instructions,
          files: [
            if (files is List)
              for (final f in files)
                if (f is String && f.trim().isNotEmpty) f.trim(),
          ],
          revise: _requiredText(item, 'revise'),
        ),
      );
    }
    if (tasks.isEmpty) return const ParseInvalid('delegate has no tasks');
    return ParseOk(Delegate(summary: _requiredText(args, 'summary') ?? '', tasks: tasks));
  }

  static ParseResult _parseAddProvider(Map<dynamic, dynamic> args) {
    final (draft, reason) = ProviderDraft.parse(args);
    return draft == null ? ParseInvalid(reason ?? 'unusable provider') : ParseOk(AddProvider(draft));
  }

  static ParseResult _parseUpdateSettings(Map<dynamic, dynamic> args) {
    switch (AgentSettings.parse(args)) {
      case SettingsPatchInvalid(:final reason):
        return ParseInvalid(reason);
      case SettingsPatch(:final changes):
        return changes.isEmpty
            ? const ParseInvalid('no changes')
            : ParseOk(UpdateSettings(changes));
    }
  }
}

class _WrongType implements Exception {
  _WrongType(this.key);
  final String key;
}
