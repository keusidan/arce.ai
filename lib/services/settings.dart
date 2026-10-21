import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/chat_controller.dart';
import '../core/engine.dart';
import '../core/settings_spec.dart';

enum GpuOffload { auto, cpuOnly, gpuPriority, maxGpu }

/// Icon shown while the model is working (see the "思考中" designs).
enum ThinkingStyle { basic, ring, pulse, dots, rotation }

/// Every user setting (spec §8, §26). Basic ones first, developer ones after.
class AppSettings {
  const AppSettings({
    this.thinking = true,
    this.searchEnabled = true,
    this.searxngUrl = '',
    this.tone = '',
    this.maxChars = 0,
    this.speedAccuracy = 0.5,
    this.hyperLoad = false,
    this.theme = ThemeMode.system,
    this.thinkingStyle = ThinkingStyle.pulse,
    this.agentOverride = '',
    this.aiAgentSelection = true,
    this.lastModelPath = '',
    this.contextLength = 4096,
    this.threads = 0,
    this.batchSize = 0,
    this.gpuOffload = GpuOffload.auto,
    this.kvCache = KvCacheType.f16,
    this.maxTokens = 2048,
    this.retryLimit = 2,
    this.maxToolRounds = 4,
    this.forceExecution = false,
    this.updateRepo = defaultRepo,
    this.autoUpdateCheck = true,
    this.updateIntervalHours = 12,
  });

  static const defaultRepo = 'keusidan/arce.ai';

  final bool thinking;
  final bool searchEnabled;
  final String searxngUrl;
  final String tone;
  final int maxChars;
  final double speedAccuracy;
  final bool hyperLoad;
  final ThemeMode theme;
  final ThinkingStyle thinkingStyle;
  final String agentOverride;
  final bool aiAgentSelection;
  final String lastModelPath;
  final int contextLength;
  final int threads;
  final int batchSize;
  final GpuOffload gpuOffload;
  final KvCacheType kvCache;
  final int maxTokens;
  final int retryLimit;
  final int maxToolRounds;
  final bool forceExecution;
  final String updateRepo;
  final bool autoUpdateCheck;
  final int updateIntervalHours;

  AppSettings copyWith({
    bool? thinking,
    bool? searchEnabled,
    String? searxngUrl,
    String? tone,
    int? maxChars,
    double? speedAccuracy,
    bool? hyperLoad,
    ThemeMode? theme,
    ThinkingStyle? thinkingStyle,
    String? agentOverride,
    bool? aiAgentSelection,
    String? lastModelPath,
    int? contextLength,
    int? threads,
    int? batchSize,
    GpuOffload? gpuOffload,
    KvCacheType? kvCache,
    int? maxTokens,
    int? retryLimit,
    int? maxToolRounds,
    bool? forceExecution,
    String? updateRepo,
    bool? autoUpdateCheck,
    int? updateIntervalHours,
  }) =>
      AppSettings(
        thinking: thinking ?? this.thinking,
        searchEnabled: searchEnabled ?? this.searchEnabled,
        searxngUrl: searxngUrl ?? this.searxngUrl,
        tone: tone ?? this.tone,
        maxChars: maxChars ?? this.maxChars,
        speedAccuracy: speedAccuracy ?? this.speedAccuracy,
        hyperLoad: hyperLoad ?? this.hyperLoad,
        theme: theme ?? this.theme,
        thinkingStyle: thinkingStyle ?? this.thinkingStyle,
        agentOverride: agentOverride ?? this.agentOverride,
        aiAgentSelection: aiAgentSelection ?? this.aiAgentSelection,
        lastModelPath: lastModelPath ?? this.lastModelPath,
        contextLength: contextLength ?? this.contextLength,
        threads: threads ?? this.threads,
        batchSize: batchSize ?? this.batchSize,
        gpuOffload: gpuOffload ?? this.gpuOffload,
        kvCache: kvCache ?? this.kvCache,
        maxTokens: maxTokens ?? this.maxTokens,
        retryLimit: retryLimit ?? this.retryLimit,
        maxToolRounds: maxToolRounds ?? this.maxToolRounds,
        forceExecution: forceExecution ?? this.forceExecution,
        updateRepo: updateRepo ?? this.updateRepo,
        autoUpdateCheck: autoUpdateCheck ?? this.autoUpdateCheck,
        updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
      );

  Map<String, Object?> toJson() => {
        'thinking': thinking,
        'searchEnabled': searchEnabled,
        'searxngUrl': searxngUrl,
        'tone': tone,
        'maxChars': maxChars,
        'speedAccuracy': speedAccuracy,
        'hyperLoad': hyperLoad,
        'theme': theme.name,
        'thinkingStyle': thinkingStyle.name,
        'agentOverride': agentOverride,
        'aiAgentSelection': aiAgentSelection,
        'lastModelPath': lastModelPath,
        'contextLength': contextLength,
        'threads': threads,
        'batchSize': batchSize,
        'gpuOffload': gpuOffload.name,
        'kvCache': kvCache.name,
        'maxTokens': maxTokens,
        'retryLimit': retryLimit,
        'maxToolRounds': maxToolRounds,
        'forceExecution': forceExecution,
        'updateRepo': updateRepo,
        'autoUpdateCheck': autoUpdateCheck,
        'updateIntervalHours': updateIntervalHours,
      };

  /// Unknown, missing or wrongly typed values fall back to the defaults, so older or damaged
  /// saves keep loading (one bad value must not reset everything else).
  factory AppSettings.fromJson(Map<String, Object?> json) {
    const d = AppSettings();
    bool flag(String key, bool fallback) => json[key] is bool ? json[key]! as bool : fallback;
    int whole(String key, int fallback) => json[key] is num ? (json[key]! as num).toInt() : fallback;
    String text(String key, String fallback) => json[key] is String ? json[key]! as String : fallback;
    T option<T extends Enum>(List<T> values, String key, T fallback) {
      for (final v in values) {
        if (v.name == json[key]) return v;
      }
      return fallback;
    }

    return AppSettings(
      thinking: flag('thinking', d.thinking),
      searchEnabled: flag('searchEnabled', d.searchEnabled),
      searxngUrl: text('searxngUrl', d.searxngUrl),
      tone: text('tone', d.tone),
      maxChars: whole('maxChars', d.maxChars),
      speedAccuracy: json['speedAccuracy'] is num ? (json['speedAccuracy']! as num).toDouble() : d.speedAccuracy,
      hyperLoad: flag('hyperLoad', d.hyperLoad),
      theme: option(ThemeMode.values, 'theme', d.theme),
      thinkingStyle: option(ThinkingStyle.values, 'thinkingStyle', d.thinkingStyle),
      agentOverride: text('agentOverride', d.agentOverride),
      aiAgentSelection: flag('aiAgentSelection', d.aiAgentSelection),
      lastModelPath: text('lastModelPath', d.lastModelPath),
      contextLength: whole('contextLength', d.contextLength),
      threads: whole('threads', d.threads),
      batchSize: whole('batchSize', d.batchSize),
      gpuOffload: option(GpuOffload.values, 'gpuOffload', d.gpuOffload),
      kvCache: option(KvCacheType.values, 'kvCache', d.kvCache),
      maxTokens: whole('maxTokens', d.maxTokens),
      retryLimit: whole('retryLimit', d.retryLimit),
      maxToolRounds: whole('maxToolRounds', d.maxToolRounds),
      forceExecution: flag('forceExecution', d.forceExecution),
      updateRepo: text('updateRepo', d.updateRepo),
      autoUpdateCheck: flag('autoUpdateCheck', d.autoUpdateCheck),
      updateIntervalHours: whole('updateIntervalHours', d.updateIntervalHours),
    );
  }

  GenerationSettings toGeneration(double? modelParamsB) => GenerationSettings(
        tone: tone.trim().isEmpty ? null : tone,
        maxChars: maxChars,
        maxTokens: maxTokens,
        searchEnabled: searchEnabled,
        retryLimit: retryLimit,
        maxToolRounds: maxToolRounds,
        speedAccuracy: speedAccuracy,
        modelParamsB: modelParamsB,
        agentOverride: agentOverride.isEmpty ? null : agentOverride,
        aiAgentSelection: aiAgentSelection,
      );

  /// Threads: explicit value, else all cores under HyperLoad, else half (spec §4 HyperLoad).
  int effectiveThreads(int cores) {
    if (threads > 0) return threads;
    if (hyperLoad) return cores < 1 ? 1 : cores;
    return (cores ~/ 2).clamp(2, 6);
  }

  int gpuLayers({required bool gpuAvailable}) => switch (gpuOffload) {
        GpuOffload.cpuOnly => 0,
        GpuOffload.gpuPriority => gpuAvailable ? 999 : 0,
        GpuOffload.maxGpu => 999,
        GpuOffload.auto => gpuAvailable ? (hyperLoad ? 999 : 20) : 0,
      };
}

/// One approved patch, written into the settings document.
///
/// [AgentSettings.normalize] has already checked every value, so writing it and letting
/// [AppSettings.fromJson] type it keeps this free of per-key code.
AppSettings withSettings(AppSettings current, List<SettingsChangeOk> changes) {
  final json = current.toJson();
  for (final change in changes) {
    json[change.key] = change.value;
  }
  return AppSettings.fromJson(json);
}

/// Settings are one JSON document in shared preferences; the GitHub token lives in the
/// platform's secure storage instead, because it can read a private repository.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs, {FlutterSecureStorage? secure}) : _secure = secure ??
            // the legacy keychain needs no entitlement or provisioning profile, so unsigned builds can use it
            const FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  static const _key = 'settings.v1';
  static const _tokenKey = 'github_token';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  AppSettings _value = const AppSettings();
  AppSettings get value => _value;

  String _token = '';

  /// Empty when none is set (or secure storage is unavailable on this system).
  String get githubToken => _token;

  static Future<SettingsStore> load({FlutterSecureStorage? secure}) async {
    final store = SettingsStore(await SharedPreferences.getInstance(), secure: secure);
    final raw = store._prefs.getString(_key);
    if (raw != null) {
      try {
        store._value = AppSettings.fromJson((jsonDecode(raw) as Map).cast());
      } catch (_) {
        // a damaged save must not block the app; the defaults apply
      }
    }
    try {
      store._token = await store._secure.read(key: _tokenKey) ?? '';
    } catch (_) {
      store._token = '';
    }
    return store;
  }

  Future<void> update(AppSettings Function(AppSettings) change) async {
    _value = change(_value);
    notifyListeners();
    await _prefs.setString(_key, jsonEncode(_value.toJson()));
  }

  Future<void> setGithubToken(String token) async {
    _token = token.trim();
    notifyListeners();
    try {
      if (_token.isEmpty) {
        await _secure.delete(key: _tokenKey);
      } else {
        await _secure.write(key: _tokenKey, value: _token);
      }
    } catch (_) {
      // keep the token for this run only when the system keyring is missing
    }
  }
}
