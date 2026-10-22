/// The settings the agent may change, with the range the app accepts for each one.
///
/// Only what is listed in [specs] can be changed. Two kinds of setting stay out of reach:
///
/// * API keys and the GitHub token. They are not part of `AppSettings` at all (they live in the
///   platform's secure storage), and the model must never read or write them.
/// * `lastModelPath` and `updateRepo`. The first is app state, not a preference; the second
///   decides where an update comes from, so pointing it somewhere else is a supply-chain
///   change that a chat message must not be able to make.
///
/// A change produced here is only a proposal: the chat shows it, and the app applies it only
/// after the user approves.
abstract final class AgentSettings {
  static const specs = <String, SettingSpec>{
    'thinking': SettingSpec(key: 'thinking', label: '思考プロセス', kind: SettingKind.flag),
    'searchEnabled': SettingSpec(key: 'searchEnabled', label: '検索', kind: SettingKind.flag),
    'searxngUrl': SettingSpec(
      key: 'searxngUrl',
      label: '検索サーバー',
      kind: SettingKind.url,
      maxLength: 300,
    ),
    'tone': SettingSpec(key: 'tone', label: '口調', kind: SettingKind.text, maxLength: 200),
    'maxChars': SettingSpec(key: 'maxChars', label: '回答の最大文字数', kind: SettingKind.whole, min: 0, max: 4000),
    'speedAccuracy': SettingSpec(
      key: 'speedAccuracy',
      label: '速度と精度',
      kind: SettingKind.decimal,
      min: 0,
      max: 1,
    ),
    'hyperLoad': SettingSpec(key: 'hyperLoad', label: 'ハイパーロード', kind: SettingKind.flag),
    'theme': SettingSpec(
      key: 'theme',
      label: 'テーマ',
      kind: SettingKind.choice,
      choices: ['system', 'light', 'dark'],
      choiceLabels: {'system': '端末に合わせる', 'light': 'ライト', 'dark': 'ダーク'},
    ),
    'thinkingStyle': SettingSpec(
      key: 'thinkingStyle',
      label: '思考中のアイコン',
      kind: SettingKind.choice,
      choices: ['basic', 'ring', 'pulse', 'dots', 'rotation'],
      choiceLabels: {
        'basic': '基本',
        'ring': 'リング',
        'pulse': 'パルス',
        'dots': 'ドット',
        'rotation': 'ローテーション',
      },
    ),
    'agentOverride': SettingSpec(
      key: 'agentOverride',
      label: 'エージェント',
      kind: SettingKind.text,
      maxLength: 40,
    ),
    'aiAgentSelection': SettingSpec(
      key: 'aiAgentSelection',
      label: 'エージェントの自動選択',
      kind: SettingKind.flag,
    ),
    'contextLength': SettingSpec(
      key: 'contextLength',
      label: 'コンテキスト長',
      kind: SettingKind.whole,
      min: 512,
      max: 131072,
    ),
    'threads': SettingSpec(key: 'threads', label: 'スレッド数', kind: SettingKind.whole, min: 0, max: 64),
    'batchSize': SettingSpec(key: 'batchSize', label: 'バッチサイズ', kind: SettingKind.whole, min: 0, max: 1024),
    'gpuOffload': SettingSpec(
      key: 'gpuOffload',
      label: 'GPU',
      kind: SettingKind.choice,
      choices: ['auto', 'cpuOnly', 'gpuPriority', 'maxGpu'],
      choiceLabels: {
        'auto': '自動',
        'cpuOnly': 'CPUのみ',
        'gpuPriority': 'GPU優先',
        'maxGpu': '最大GPU',
      },
    ),
    'maxTokens': SettingSpec(
      key: 'maxTokens',
      label: '最大トークン',
      kind: SettingKind.whole,
      min: 256,
      max: 32768,
    ),
    'retryLimit': SettingSpec(
      key: 'retryLimit',
      label: 'エラー再書き込み回数',
      kind: SettingKind.whole,
      min: 0,
      max: 10,
    ),
    'maxToolRounds': SettingSpec(
      key: 'maxToolRounds',
      label: 'ツール呼び出しの上限',
      kind: SettingKind.whole,
      min: 0,
      max: 20,
    ),
    'forceExecution': SettingSpec(key: 'forceExecution', label: '強制実行', kind: SettingKind.flag),
    'autoUpdateCheck': SettingSpec(
      key: 'autoUpdateCheck',
      label: '更新の自動確認',
      kind: SettingKind.flag,
    ),
    'updateIntervalHours': SettingSpec(
      key: 'updateIntervalHours',
      label: '更新確認の間隔（時間）',
      kind: SettingKind.whole,
      min: 1,
      max: 168,
    ),
    'autoInstallUpdate': SettingSpec(
      key: 'autoInstallUpdate',
      label: '更新の自動インストール',
      kind: SettingKind.flag,
    ),
    // The device model and the online models have their own set; -1 (0 for a token count, empty
    // for a prompt) means "not set", and the app's own value applies.
    'localTemperature': SettingSpec(
      key: 'localTemperature',
      label: 'ローカル: temperature（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 2,
    ),
    'localTopP': SettingSpec(
      key: 'localTopP',
      label: 'ローカル: top_p（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 1,
    ),
    'localTopK': SettingSpec(
      key: 'localTopK',
      label: 'ローカル: top_k（0で既定）',
      kind: SettingKind.whole,
      min: 0,
      max: 200,
    ),
    'localMinP': SettingSpec(
      key: 'localMinP',
      label: 'ローカル: min_p（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 1,
    ),
    'localMaxTokens': SettingSpec(
      key: 'localMaxTokens',
      label: 'ローカル: 最大トークン（0で共通の値）',
      kind: SettingKind.whole,
      min: 0,
      max: 32768,
    ),
    'localPrompt': SettingSpec(
      key: 'localPrompt',
      label: 'ローカル: 追加プロンプト',
      kind: SettingKind.text,
      maxLength: 2000,
    ),
    'onlineTemperature': SettingSpec(
      key: 'onlineTemperature',
      label: 'オンライン: temperature（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 2,
    ),
    'onlineTopP': SettingSpec(
      key: 'onlineTopP',
      label: 'オンライン: top_p（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 1,
    ),
    'onlineMaxTokens': SettingSpec(
      key: 'onlineMaxTokens',
      label: 'オンライン: 最大トークン（0で共通の値）',
      kind: SettingKind.whole,
      min: 0,
      max: 32768,
    ),
    'onlinePrompt': SettingSpec(
      key: 'onlinePrompt',
      label: 'オンライン: 追加プロンプト',
      kind: SettingKind.text,
      maxLength: 2000,
    ),
    // Coding mode: a design model and a developer model share the coding agent's work. A model is
    // written `providerId|modelId` (`local|` is the model on the device).
    'codingPlanEnabled': SettingSpec(
      key: 'codingPlanEnabled',
      label: 'コーディングモード（設計＋開発の分担）',
      kind: SettingKind.flag,
    ),
    'plannerModel': SettingSpec(key: 'plannerModel', label: '設計モデル（provider|model）', kind: SettingKind.text, maxLength: 120),
    'developerModel': SettingSpec(key: 'developerModel', label: '開発モデル（provider|model）', kind: SettingKind.text, maxLength: 120),
    'codingMaxTasks': SettingSpec(
      key: 'codingMaxTasks',
      label: 'コーディング: タスクの最大数',
      kind: SettingKind.whole,
      min: 1,
      max: 8,
    ),
    'codingParallel': SettingSpec(
      key: 'codingParallel',
      label: 'コーディング: 同時に走らせる数',
      kind: SettingKind.whole,
      min: 1,
      max: 8,
    ),
    'codingReviewRounds': SettingSpec(
      key: 'codingReviewRounds',
      label: 'コーディング: レビューの回数',
      kind: SettingKind.whole,
      min: 0,
      max: 3,
    ),
    'codingPlannerMaxTokens': SettingSpec(
      key: 'codingPlannerMaxTokens',
      label: 'コーディング: 設計モデルの最大トークン',
      kind: SettingKind.whole,
      min: 256,
      max: 32768,
    ),
    'codingDeveloperMaxTokens': SettingSpec(
      key: 'codingDeveloperMaxTokens',
      label: 'コーディング: 開発モデルの最大トークン',
      kind: SettingKind.whole,
      min: 256,
      max: 32768,
    ),
    // limits and timeouts
    'attachMaxFiles': SettingSpec(
      key: 'attachMaxFiles',
      label: '添付できるファイルの数',
      kind: SettingKind.whole,
      min: 1,
      max: 20,
    ),
    'attachCharsPerFile': SettingSpec(
      key: 'attachCharsPerFile',
      label: '添付1ファイルから読む文字数',
      kind: SettingKind.whole,
      min: 500,
      max: 200000,
    ),
    'attachTotalChars': SettingSpec(
      key: 'attachTotalChars',
      label: '添付全体で読む文字数',
      kind: SettingKind.whole,
      min: 1000,
      max: 400000,
    ),
    'attachImageMb': SettingSpec(
      key: 'attachImageMb',
      label: '送る画像の大きさの上限（MB）',
      kind: SettingKind.whole,
      min: 1,
      max: 20,
    ),
    'searchResultCount': SettingSpec(
      key: 'searchResultCount',
      label: '検索結果の件数',
      kind: SettingKind.whole,
      min: 1,
      max: 20,
    ),
    'httpTimeoutSeconds': SettingSpec(
      key: 'httpTimeoutSeconds',
      label: '検索・天気の通信のタイムアウト（秒）',
      kind: SettingKind.whole,
      min: 3,
      max: 300,
    ),
    'mcpTimeoutSeconds': SettingSpec(
      key: 'mcpTimeoutSeconds',
      label: 'MCPサーバーのタイムアウト（秒）',
      kind: SettingKind.whole,
      min: 5,
      max: 600,
    ),
    'providerTimeoutSeconds': SettingSpec(
      key: 'providerTimeoutSeconds',
      label: 'オンラインモデルの応答のタイムアウト（秒）',
      kind: SettingKind.whole,
      min: 10,
      max: 1800,
    ),
    'toolRepeatLimit': SettingSpec(
      key: 'toolRepeatLimit',
      label: '同じツール呼び出しの繰り返しで止める回数',
      kind: SettingKind.whole,
      min: 2,
      max: 10,
    ),
    'updateRetryAttempts': SettingSpec(
      key: 'updateRetryAttempts',
      label: '更新ダウンロードの試行回数',
      kind: SettingKind.whole,
      min: 1,
      max: 20,
    ),
    'updateStallSeconds': SettingSpec(
      key: 'updateStallSeconds',
      label: '更新ダウンロードの無通信の判定（秒）',
      kind: SettingKind.whole,
      min: 5,
      max: 600,
    ),
    'localDryMultiplier': SettingSpec(
      key: 'localDryMultiplier',
      label: 'ローカル: 繰り返しの抑制 DRY（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 5,
    ),
  };

  /// Sorted, so the grammar and the prompt show the same order every time.
  static List<String> get keys => specs.keys.toList()..sort();

  /// The names of the settings that are deliberately not reachable from a chat message.
  static const blocked = <String>{'lastModelPath', 'updateRepo', 'kvCache'};

  static bool isEditable(String key) => specs.containsKey(key);

  /// Checks one value against its setting and converts it to what the app stores.
  static SettingsChangeResult normalize(String key, Object? raw) {
    final spec = specs[key];
    if (spec == null) {
      if (blocked.contains(key)) return SettingsChangeInvalid(key, '$key はチャットからは変更できません');
      return SettingsChangeInvalid(key, '$key という設定はありません');
    }

    switch (spec.kind) {
      case SettingKind.flag:
        final value = _flag(raw);
        if (value == null) return SettingsChangeInvalid(key, '${spec.label}は true か false で指定してください');
        return SettingsChangeOk(spec, value);

      case SettingKind.whole:
        final value = _number(raw);
        if (value == null || value != value.roundToDouble()) {
          return SettingsChangeInvalid(key, '${spec.label}は整数で指定してください');
        }
        final whole = value.toInt();
        return _range(spec, whole) ?? SettingsChangeOk(spec, whole);

      case SettingKind.decimal:
        final value = _number(raw);
        if (value == null) return SettingsChangeInvalid(key, '${spec.label}は数値で指定してください');
        return _range(spec, value) ?? SettingsChangeOk(spec, value);

      case SettingKind.choice:
        final text = raw?.toString().trim();
        if (text == null || !spec.choices.contains(text)) {
          return SettingsChangeInvalid(
            key,
            '${spec.label}は ${spec.choices.join(' / ')} のどれかで指定してください',
          );
        }
        return SettingsChangeOk(spec, text);

      case SettingKind.text:
      case SettingKind.url:
        if (raw is! String) return SettingsChangeInvalid(key, '${spec.label}は文字列で指定してください');
        final text = raw.trim();
        final maxLength = spec.maxLength;
        if (maxLength != null && text.length > maxLength) {
          return SettingsChangeInvalid(key, '${spec.label}は$maxLength文字までです');
        }
        if (spec.kind == SettingKind.url && text.isNotEmpty) {
          final uri = Uri.tryParse(text);
          if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
            return SettingsChangeInvalid(key, '${spec.label}は http(s) のURLで指定してください');
          }
        }
        return SettingsChangeOk(spec, text);
    }
  }

  /// Reads the argument object of the `update_settings` tool call.
  ///
  /// `{"changes": [{"key": "thinking", "value": false}, ...]}` — the same key twice keeps the
  /// last value, so a model that repeats itself does not produce two cards.
  static SettingsPatchResult parse(Object? arguments) {
    if (arguments is! Map) return const SettingsPatchInvalid('引数がオブジェクトではありません');
    final raw = arguments['changes'];
    if (raw is! List) return const SettingsPatchInvalid('changes が配列ではありません');
    if (raw.isEmpty) return const SettingsPatchInvalid('変更が1つもありません');
    if (raw.length > maxChanges) {
      return const SettingsPatchInvalid('一度に変更できるのは$maxChanges件までです');
    }

    final byKey = <String, SettingsChangeOk>{};
    for (final item in raw) {
      if (item is! Map) return const SettingsPatchInvalid('changes の要素がオブジェクトではありません');
      final key = item['key'];
      if (key is! String) return const SettingsPatchInvalid('key がありません');
      switch (normalize(key, item['value'])) {
        case SettingsChangeInvalid(:final reason):
          return SettingsPatchInvalid(reason);
        case final SettingsChangeOk ok:
          byKey[ok.key] = ok;
      }
    }
    return SettingsPatch(byKey.values.toList());
  }

  static const maxChanges = 6;

  static SettingsChangeInvalid? _range(SettingSpec spec, num value) {
    final min = spec.min;
    final max = spec.max;
    if (min != null && value < min) return SettingsChangeInvalid(spec.key, '${spec.label}は$min以上にしてください');
    if (max != null && value > max) return SettingsChangeInvalid(spec.key, '${spec.label}は$max以下にしてください');
    return null;
  }

  static bool? _flag(Object? raw) {
    if (raw is bool) return raw;
    if (raw is String) {
      final text = raw.trim().toLowerCase();
      if (text == 'true') return true;
      if (text == 'false') return false;
    }
    return null;
  }

  static double? _number(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw.trim());
    return null;
  }

  /// The text `get_settings` returns: every setting the model may change, with its current value,
  /// its label and what the app accepts for it, so the model can answer questions about the app
  /// without guessing and can pick a legal value for a change.
  static String describe(Map<String, Object?> values) {
    final b = StringBuffer();
    for (final key in keys) {
      final spec = specs[key]!;
      final value = values[key];
      b
        ..write('- $key = ')
        ..write(_formatValue(value))
        ..write('  # ${spec.label}');
      if (spec.kind == SettingKind.choice) {
        final labels = [for (final c in spec.choices) '$c（${spec.choiceLabels[c] ?? c}）'];
        b.write('、選択肢: ${labels.join(' / ')}');
      }
      if (spec.min != null || spec.max != null) {
        b.write('、範囲: ${spec.min ?? ''}〜${spec.max ?? ''}');
      }
      if (spec.maxLength != null) b.write('、${spec.maxLength}文字まで');
      b.write('\n');
    }
    b.write('次はチャットからは読むことも変えることもできません：APIキーとGitHubトークンは端末の'
        '安全な領域にあり、${blocked.join('、')} はアプリの状態かアップデートの取得元だからです。');
    return b.toString();
  }

  /// The stored value as the model sees it (a choice by its name, not its label).
  static String _formatValue(Object? value) {
    if (value == null) return '（未設定）';
    if (value is bool) return value ? 'true' : 'false';
    if (value is String) return value.isEmpty ? '（空）' : value;
    return '$value';
  }
}

enum SettingKind { flag, whole, decimal, choice, text, url }

class SettingSpec {
  const SettingSpec({
    required this.key,
    required this.label,
    required this.kind,
    this.choices = const [],
    this.choiceLabels = const {},
    this.min,
    this.max,
    this.maxLength,
  });

  final String key;

  /// What the confirmation card calls it.
  final String label;
  final SettingKind kind;
  final List<String> choices;
  final Map<String, String> choiceLabels;
  final num? min;
  final num? max;
  final int? maxLength;

  /// How the value reads on the confirmation card.
  String format(Object? value) => switch (kind) {
        SettingKind.flag => value == true ? 'オン' : 'オフ',
        SettingKind.choice => choiceLabels[value] ?? '$value',
        SettingKind.text || SettingKind.url => value == null || '$value'.isEmpty ? '（空）' : '「$value」',
        SettingKind.whole || SettingKind.decimal => '$value',
      };
}

sealed class SettingsChangeResult {
  const SettingsChangeResult();
}

/// One accepted change, ready to show and to apply.
class SettingsChangeOk extends SettingsChangeResult {
  const SettingsChangeOk(this.spec, this.value);

  final SettingSpec spec;
  final Object value;

  String get key => spec.key;

  /// e.g. `思考プロセスを「オフ」にする`.
  String get description => '${spec.label}を${spec.format(value)}にする';
}

class SettingsChangeInvalid extends SettingsChangeResult {
  const SettingsChangeInvalid(this.key, this.reason);

  final String key;
  final String reason;
}

sealed class SettingsPatchResult {
  const SettingsPatchResult();
}

/// The whole call is accepted; [changes] has one entry per distinct key.
class SettingsPatch extends SettingsPatchResult {
  const SettingsPatch(this.changes);

  final List<SettingsChangeOk> changes;
}

class SettingsPatchInvalid extends SettingsPatchResult {
  const SettingsPatchInvalid(this.reason);

  final String reason;
}
