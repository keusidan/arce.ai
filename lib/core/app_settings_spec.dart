/// The app's own settings as a tool sees them: every key of [AppSettings.toJson] with its label,
/// its type, its allowed choices or range, and the parsing that turns the string the model sends
/// back into the typed value.
///
/// The GitHub token is deliberately absent: it lives in secure storage, it can read a private
/// repository, and no tool reads or changes it (README, "アップデート"; spec §8).
enum SettingKind { flag, whole, decimal, text, choice }

/// One entry of the settings document. [key] is the JSON key, so a change needs no per-key code.
class SettingSpec {
  const SettingSpec({
    required this.key,
    required this.label,
    required this.kind,
    this.note = '',
    this.min,
    this.max,
    this.choices = const [],
    this.readOnly = false,
  });

  final String key;

  /// Shown to the user in the approval card and to the model in `get_app_settings`.
  final String label;
  final SettingKind kind;

  /// Free text for the model, e.g. what 0 means or when the value takes effect.
  final String note;
  final int? min;
  final int? max;

  /// Allowed values of a [SettingKind.choice]; the enum names used in the saved document.
  final List<String> choices;

  /// Readable but not changeable (the model must not point the app at another model file).
  final bool readOnly;

  bool get settable => !readOnly;
}

/// A value the model may write, already checked against its [SettingSpec].
class SettingChange {
  const SettingChange(this.spec, this.value);

  final SettingSpec spec;

  /// bool for a flag, int for a whole number, double for a decimal, String otherwise.
  final Object value;

  String get display => SettingsCatalog.formatValue(spec, value);
}

abstract final class SettingsCatalog {
  /// Every setting the model may read; the order is the order of the 詳細設定 page.
  static const specs = <SettingSpec>[
    SettingSpec(key: 'thinking', label: '思考プロセスを表示', kind: SettingKind.flag),
    SettingSpec(key: 'searchEnabled', label: 'Web検索', kind: SettingKind.flag),
    SettingSpec(
      key: 'searxngUrl',
      label: 'SearXNGのURL',
      kind: SettingKind.text,
      max: 300,
      note: '空なら DuckDuckGo だけを使う',
    ),
    SettingSpec(key: 'tone', label: '口調', kind: SettingKind.text, max: 200),
    SettingSpec(
      key: 'maxChars',
      label: '返信の最大文字数',
      kind: SettingKind.whole,
      min: 0,
      max: 10000,
      note: '0 は無制限',
    ),
    SettingSpec(
      key: 'speedAccuracy',
      label: '速度と精度',
      kind: SettingKind.decimal,
      min: 0,
      max: 1,
      note: '0 が最速、1 が最も正確',
    ),
    SettingSpec(key: 'hyperLoad', label: 'HyperLoad（全コアを使う）', kind: SettingKind.flag),
    SettingSpec(key: 'theme', label: 'テーマ', kind: SettingKind.choice, choices: ['system', 'light', 'dark']),
    SettingSpec(
      key: 'thinkingStyle',
      label: '思考中のアイコン',
      kind: SettingKind.choice,
      choices: ['basic', 'ring', 'pulse', 'dots', 'rotation'],
    ),
    SettingSpec(
      key: 'agentOverride',
      label: '固定するエージェント',
      kind: SettingKind.choice,
      choices: ['', 'general', 'coding', 'research', 'artifact', 'file-analysis'],
      note: '空は自動',
    ),
    SettingSpec(key: 'aiAgentSelection', label: 'エージェント選択をAIに任せる', kind: SettingKind.flag),
    SettingSpec(
      key: 'lastModelPath',
      label: '最後に読み込んだモデル',
      kind: SettingKind.text,
      readOnly: true,
      note: 'アプリが読み込み時に書く',
    ),
    SettingSpec(
      key: 'contextLength',
      label: 'コンテキスト長',
      kind: SettingKind.whole,
      min: 512,
      max: 131072,
      note: '次にモデルを読み込んだときから有効',
    ),
    SettingSpec(
      key: 'threads',
      label: 'スレッド数',
      kind: SettingKind.whole,
      min: 0,
      max: 64,
      note: '0 は自動。次にモデルを読み込んだときから有効',
    ),
    SettingSpec(
      key: 'batchSize',
      label: 'バッチサイズ',
      kind: SettingKind.whole,
      min: 0,
      max: 8192,
      note: '0 は llama.cpp の既定。次にモデルを読み込んだときから有効',
    ),
    SettingSpec(
      key: 'gpuOffload',
      label: 'GPUへの割り当て',
      kind: SettingKind.choice,
      choices: ['auto', 'cpuOnly', 'gpuPriority', 'maxGpu'],
      note: '次にモデルを読み込んだときから有効',
    ),
    SettingSpec(
      key: 'kvCache',
      label: 'KVキャッシュの型',
      kind: SettingKind.choice,
      choices: ['f16', 'q8_0'],
      note: '次にモデルを読み込んだときから有効',
    ),
    SettingSpec(
      key: 'maxTokens',
      label: '1回の返信の最大トークン数',
      kind: SettingKind.whole,
      min: 128,
      max: 32768,
    ),
    SettingSpec(key: 'retryLimit', label: 'エラー再書き込み回数', kind: SettingKind.whole, min: 0, max: 5),
    SettingSpec(key: 'maxToolRounds', label: 'ツール呼び出しの上限回数', kind: SettingKind.whole, min: 1, max: 16),
    SettingSpec(key: 'forceExecution', label: '強制実行', kind: SettingKind.flag),
    SettingSpec(
      key: 'updateRepo',
      label: 'アップデートの取得元（owner/repo）',
      kind: SettingKind.text,
      max: 100,
    ),
    SettingSpec(key: 'autoUpdateCheck', label: 'アップデートを自動確認', kind: SettingKind.flag),
    SettingSpec(
      key: 'updateIntervalHours',
      label: 'アップデート確認の間隔（時間）',
      kind: SettingKind.whole,
      min: 1,
      max: 168,
    ),
  ];

  /// Settings a running model keeps until it is loaded again.
  static const reloadNeeded = {'contextLength', 'threads', 'batchSize', 'gpuOffload', 'kvCache'};

  static SettingSpec? byKey(String key) {
    for (final spec in specs) {
      if (spec.key == key) return spec;
    }
    return null;
  }

  /// The key list for the tool description: the model cannot invent a key the parser would reject.
  static String keysForPrompt() => [
        for (final spec in specs)
          if (spec.settable) '${spec.key}(${_kindName(spec)})',
      ].join(', ');

  static String _kindName(SettingSpec spec) => switch (spec.kind) {
        SettingKind.flag => 'true/false',
        SettingKind.whole => '整数',
        SettingKind.decimal => '小数',
        SettingKind.text => '文字列',
        SettingKind.choice => 'いずれか: ${spec.choices.join('|')}',
      };

  /// The model sends every value as a string; this turns it into the typed value, or null when the
  /// key is unknown, read-only, or the value is outside what the settings page accepts.
  static SettingChange? parse(String key, String raw) {
    final spec = byKey(key);
    if (spec == null || spec.readOnly) return null;
    final text = raw.trim();
    switch (spec.kind) {
      case SettingKind.flag:
        final value = _flag(text);
        return value == null ? null : SettingChange(spec, value);
      case SettingKind.whole:
        final value = int.tryParse(text);
        return value == null || !_inRange(spec, value) ? null : SettingChange(spec, value);
      case SettingKind.decimal:
        final value = double.tryParse(text);
        return value == null || !_inRange(spec, value) ? null : SettingChange(spec, value);
      case SettingKind.choice:
        return spec.choices.contains(text) ? SettingChange(spec, text) : null;
      case SettingKind.text:
        return spec.max != null && text.length > spec.max! ? null : SettingChange(spec, text);
    }
  }

  /// Rebuilds a pending change from a saved conversation; null when the entry is damaged or the
  /// catalog has changed since (the approval card is then simply not shown).
  static SettingChange? fromStored(Object? key, Object? value) {
    if (key is! String) return null;
    final spec = byKey(key);
    if (spec == null || spec.readOnly) return null;
    switch (spec.kind) {
      case SettingKind.flag:
        return value is bool ? SettingChange(spec, value) : null;
      case SettingKind.whole:
        return value is int && _inRange(spec, value) ? SettingChange(spec, value) : null;
      case SettingKind.decimal:
        return value is num && _inRange(spec, value) ? SettingChange(spec, value.toDouble()) : null;
      case SettingKind.choice:
        return value is String && spec.choices.contains(value) ? SettingChange(spec, value) : null;
      case SettingKind.text:
        return value is String && (spec.max == null || value.length <= spec.max!)
            ? SettingChange(spec, value)
            : null;
    }
  }

  /// The text `get_app_settings` returns: every value with its label, so the model can answer
  /// questions about the app without guessing, and can pick a legal value for a change.
  static String describe(Map<String, Object?> values) {
    final b = StringBuffer();
    for (final spec in specs) {
      final value = values[spec.key];
      b
        ..write('- ${spec.key} = ')
        ..write(value == null ? '(未設定)' : formatValue(spec, value))
        ..write(' # ${spec.label}');
      if (spec.kind == SettingKind.choice) b.write('、選択肢: ${spec.choices.join(' / ')}');
      if (spec.kind == SettingKind.whole || spec.kind == SettingKind.decimal) {
        final range = [if (spec.min != null) '${spec.min}', if (spec.max != null) '${spec.max}'];
        if (range.isNotEmpty) b.write('、範囲: ${range.join('〜')}');
      }
      if (spec.readOnly) b.write('、読み取り専用');
      if (spec.note.isNotEmpty) b.write('、${spec.note}');
      b.write('\n');
    }
    b.write('GitHubトークンは別の保管場所にあり、読み取りも変更もできません。');
    return b.toString();
  }

  static String formatValue(SettingSpec spec, Object value) =>
      value is String ? (value.isEmpty ? '(空)' : value) : '$value';

  static bool _inRange(SettingSpec spec, num value) =>
      (spec.min == null || value >= spec.min!) && (spec.max == null || value <= spec.max!);

  static bool? _flag(String text) {
    const yes = {'true', 'on', 'yes', '1', 'オン', '有効'};
    const no = {'false', 'off', 'no', '0', 'オフ', '無効'};
    final lower = text.toLowerCase();
    if (yes.contains(lower)) return true;
    if (no.contains(lower)) return false;
    return null;
  }
}
