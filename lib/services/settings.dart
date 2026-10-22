import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/attachments.dart';
import '../core/chat_controller.dart';
import '../core/coding_plan.dart';
import '../core/engine.dart';
import '../core/search.dart';
import '../core/settings_spec.dart';
import '../mcp/mcp_server.dart';
import 'kv_snapshots.dart';

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
    this.autoInstallUpdate = true,
    this.mcpServers = const [],
    this.searchApis = const [],
    this.updateIntervalHours = 12,
    this.localTemperature = -1,
    this.localTopP = -1,
    this.localTopK = 0,
    this.localMinP = -1,
    this.localMaxTokens = 0,
    this.localPrompt = '',
    this.onlineTemperature = -1,
    this.onlineTopP = -1,
    this.onlineMaxTokens = 0,
    this.onlinePrompt = '',
    this.codingPlanEnabled = false,
    this.plannerModel = '',
    this.developerModel = '',
    this.codingMaxTasks = 4,
    this.codingParallel = 3,
    this.codingReviewRounds = 1,
    this.codingPlannerMaxTokens = 0,
    this.codingDeveloperMaxTokens = 0,
    this.attachMaxFiles = 5,
    this.attachCharsPerFile = 8000,
    this.attachTotalChars = 16000,
    this.attachImageMb = 4,
    this.searchResultCount = 5,
    this.httpTimeoutSeconds = 20,
    this.mcpTimeoutSeconds = 40,
    this.providerTimeoutSeconds = 120,
    this.toolRepeatLimit = 3,
    this.updateRetryAttempts = 5,
    this.updateStallSeconds = 30,
    this.localDryMultiplier = -1,
    this.kvSnapshotEnabled = false,
    this.kvSnapshotMaxMb = 1024,
    this.kvSnapshotMinTokens = 512,
    this.autoFetchModelInfo = true,
    this.fetchModelInfoFromHub = true,
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

  /// Download a newer build as soon as it is found and open the installer without being asked.
  final bool autoInstallUpdate;
  final int updateIntervalHours;

  // ---- model settings, kept apart for the model on the device and for the online models ----
  //
  // For a number, -1 (0 for a token count, empty for a prompt) means "not set": the app's own value
  // applies. An online model's own settings (see `ModelConfig`) win over the online ones here.

  /// Sampling of the model on the device: temperature, top-p, top-k and min-p.
  final double localTemperature;
  final double localTopP;
  final int localTopK;
  final double localMinP;

  /// The reply length the device model starts from, before "速度と精度" scales it.
  final int localMaxTokens;

  /// Extra instruction sent only to the device model.
  final String localPrompt;

  /// The same for online models that do not set their own.
  final double onlineTemperature;
  final double onlineTopP;
  final int onlineMaxTokens;
  final String onlinePrompt;

  // ---- coding mode: a design model and a developer model share the work ----

  /// Split the coding agent's work between [plannerModel] and [developerModel].
  final bool codingPlanEnabled;

  /// `provider|model` of the model that designs and reviews (`local|` is the model on the device).
  final String plannerModel;

  /// `provider|model` of the model that writes the code.
  final String developerModel;
  final int codingMaxTasks;
  final int codingParallel;
  final int codingReviewRounds;
  final int codingPlannerMaxTokens;
  final int codingDeveloperMaxTokens;

  // ---- limits and timeouts that used to be fixed in the code ----

  /// How much of the attached files reaches the model (see `AttachmentPolicy`).
  final int attachMaxFiles;
  final int attachCharsPerFile;
  final int attachTotalChars;

  /// The biggest picture that is sent, in megabytes.
  final int attachImageMb;

  /// How many web search results a search keeps.
  final int searchResultCount;

  /// Seconds before a web search or a weather request gives up.
  final int httpTimeoutSeconds;

  /// Seconds before a call to an MCP server gives up.
  final int mcpTimeoutSeconds;

  /// Seconds an online model may take to answer a request before it gives up.
  final int providerTimeoutSeconds;

  /// How many identical tool calls in a row count as a loop.
  final int toolRepeatLimit;

  /// How many times an update download is tried, and how many silent seconds end a try.
  final int updateRetryAttempts;
  final int updateStallSeconds;

  /// DRY, the repetition penalty of the device model; -1 keeps the app's own value.
  final double localDryMultiplier;

  // ---- saving the device model's KV cache to files ----

  /// Keep the work done on a conversation's prompt in a file, so opening it again skips it.
  final bool kvSnapshotEnabled;

  /// All saved caches together stay under this many megabytes (the one used longest ago goes).
  final int kvSnapshotMaxMb;

  /// A prompt shorter than this is not saved.
  final int kvSnapshotMinTokens;

  // ---- finding out what an online model can do ----

  /// Ask the provider (and the Hub) for a model's limits when it is first used.
  final bool autoFetchModelInfo;

  /// Let that also read the context window from the model's `config.json` on huggingface.co
  /// (only the model's name is sent).
  final bool fetchModelInfoFromHub;

  KvSnapshotConfig get kvSnapshot => KvSnapshotConfig(
    enabled: kvSnapshotEnabled,
    maxBytes: kvSnapshotMaxMb.clamp(64, 65536) * 1024 * 1024,
    minTokens: kvSnapshotMinTokens.clamp(64, 100000),
  );

  AttachmentLimits get attachmentLimits => AttachmentLimits(
    maxFiles: attachMaxFiles.clamp(1, 20),
    maxCharsPerFile: attachCharsPerFile.clamp(500, 200000),
    maxTotalChars: attachTotalChars.clamp(1000, 400000),
    maxImageBytes: attachImageMb.clamp(1, 20) * 1024 * 1024,
  );

  CodingSettings get coding => CodingSettings(
    enabled: codingPlanEnabled,
    planner: plannerModel,
    developer: developerModel,
    maxTasks: codingMaxTasks.clamp(1, 8),
    parallel: codingParallel.clamp(1, 8),
    reviewRounds: codingReviewRounds.clamp(0, 3),
    plannerMaxTokens: codingPlannerMaxTokens <= 0 ? 0 : codingPlannerMaxTokens.clamp(256, 1048576),
    developerMaxTokens: codingDeveloperMaxTokens <= 0 ? 0 : codingDeveloperMaxTokens.clamp(256, 1048576),
  );

  /// The MCP servers the chat may use (Streamable HTTP). Tokens live in secure storage.
  final List<McpServerConfig> mcpServers;

  /// Search services the user set up (their keys are in the secure storage, not here).
  final List<SearchApiConfig> searchApis;

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
    bool? autoInstallUpdate,
    int? updateIntervalHours,
    List<McpServerConfig>? mcpServers,
    List<SearchApiConfig>? searchApis,
    double? localTemperature,
    double? localTopP,
    int? localTopK,
    double? localMinP,
    int? localMaxTokens,
    String? localPrompt,
    double? onlineTemperature,
    double? onlineTopP,
    int? onlineMaxTokens,
    String? onlinePrompt,
    bool? codingPlanEnabled,
    String? plannerModel,
    String? developerModel,
    int? codingMaxTasks,
    int? codingParallel,
    int? codingReviewRounds,
    int? codingPlannerMaxTokens,
    int? codingDeveloperMaxTokens,
    int? attachMaxFiles,
    int? attachCharsPerFile,
    int? attachTotalChars,
    int? attachImageMb,
    int? searchResultCount,
    int? httpTimeoutSeconds,
    int? mcpTimeoutSeconds,
    int? providerTimeoutSeconds,
    int? toolRepeatLimit,
    int? updateRetryAttempts,
    int? updateStallSeconds,
    double? localDryMultiplier,
    bool? kvSnapshotEnabled,
    int? kvSnapshotMaxMb,
    int? kvSnapshotMinTokens,
    bool? autoFetchModelInfo,
    bool? fetchModelInfoFromHub,
  }) => AppSettings(
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
    autoInstallUpdate: autoInstallUpdate ?? this.autoInstallUpdate,
    updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
    mcpServers: mcpServers ?? this.mcpServers,
    searchApis: searchApis ?? this.searchApis,
    localTemperature: localTemperature ?? this.localTemperature,
    localTopP: localTopP ?? this.localTopP,
    localTopK: localTopK ?? this.localTopK,
    localMinP: localMinP ?? this.localMinP,
    localMaxTokens: localMaxTokens ?? this.localMaxTokens,
    localPrompt: localPrompt ?? this.localPrompt,
    onlineTemperature: onlineTemperature ?? this.onlineTemperature,
    onlineTopP: onlineTopP ?? this.onlineTopP,
    onlineMaxTokens: onlineMaxTokens ?? this.onlineMaxTokens,
    onlinePrompt: onlinePrompt ?? this.onlinePrompt,
    codingPlanEnabled: codingPlanEnabled ?? this.codingPlanEnabled,
    plannerModel: plannerModel ?? this.plannerModel,
    developerModel: developerModel ?? this.developerModel,
    codingMaxTasks: codingMaxTasks ?? this.codingMaxTasks,
    codingParallel: codingParallel ?? this.codingParallel,
    codingReviewRounds: codingReviewRounds ?? this.codingReviewRounds,
    codingPlannerMaxTokens: codingPlannerMaxTokens ?? this.codingPlannerMaxTokens,
    codingDeveloperMaxTokens: codingDeveloperMaxTokens ?? this.codingDeveloperMaxTokens,
    attachMaxFiles: attachMaxFiles ?? this.attachMaxFiles,
    attachCharsPerFile: attachCharsPerFile ?? this.attachCharsPerFile,
    attachTotalChars: attachTotalChars ?? this.attachTotalChars,
    attachImageMb: attachImageMb ?? this.attachImageMb,
    searchResultCount: searchResultCount ?? this.searchResultCount,
    httpTimeoutSeconds: httpTimeoutSeconds ?? this.httpTimeoutSeconds,
    mcpTimeoutSeconds: mcpTimeoutSeconds ?? this.mcpTimeoutSeconds,
    providerTimeoutSeconds: providerTimeoutSeconds ?? this.providerTimeoutSeconds,
    toolRepeatLimit: toolRepeatLimit ?? this.toolRepeatLimit,
    updateRetryAttempts: updateRetryAttempts ?? this.updateRetryAttempts,
    updateStallSeconds: updateStallSeconds ?? this.updateStallSeconds,
    localDryMultiplier: localDryMultiplier ?? this.localDryMultiplier,
    kvSnapshotEnabled: kvSnapshotEnabled ?? this.kvSnapshotEnabled,
    kvSnapshotMaxMb: kvSnapshotMaxMb ?? this.kvSnapshotMaxMb,
    kvSnapshotMinTokens: kvSnapshotMinTokens ?? this.kvSnapshotMinTokens,
    autoFetchModelInfo: autoFetchModelInfo ?? this.autoFetchModelInfo,
    fetchModelInfoFromHub: fetchModelInfoFromHub ?? this.fetchModelInfoFromHub,
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
    'autoInstallUpdate': autoInstallUpdate,
    'updateIntervalHours': updateIntervalHours,
    'mcpServers': [for (final server in mcpServers) server.toJson()],
    'searchApis': [for (final api in searchApis) api.toJson()],
    'localTemperature': localTemperature,
    'localTopP': localTopP,
    'localTopK': localTopK,
    'localMinP': localMinP,
    'localMaxTokens': localMaxTokens,
    'localPrompt': localPrompt,
    'onlineTemperature': onlineTemperature,
    'onlineTopP': onlineTopP,
    'onlineMaxTokens': onlineMaxTokens,
    'onlinePrompt': onlinePrompt,
    'codingPlanEnabled': codingPlanEnabled,
    'plannerModel': plannerModel,
    'developerModel': developerModel,
    'codingMaxTasks': codingMaxTasks,
    'codingParallel': codingParallel,
    'codingReviewRounds': codingReviewRounds,
    'codingPlannerMaxTokens': codingPlannerMaxTokens,
    'codingDeveloperMaxTokens': codingDeveloperMaxTokens,
    'attachMaxFiles': attachMaxFiles,
    'attachCharsPerFile': attachCharsPerFile,
    'attachTotalChars': attachTotalChars,
    'attachImageMb': attachImageMb,
    'searchResultCount': searchResultCount,
    'httpTimeoutSeconds': httpTimeoutSeconds,
    'mcpTimeoutSeconds': mcpTimeoutSeconds,
    'providerTimeoutSeconds': providerTimeoutSeconds,
    'toolRepeatLimit': toolRepeatLimit,
    'updateRetryAttempts': updateRetryAttempts,
    'updateStallSeconds': updateStallSeconds,
    'localDryMultiplier': localDryMultiplier,
    'kvSnapshotEnabled': kvSnapshotEnabled,
    'kvSnapshotMaxMb': kvSnapshotMaxMb,
    'kvSnapshotMinTokens': kvSnapshotMinTokens,
    'autoFetchModelInfo': autoFetchModelInfo,
    'fetchModelInfoFromHub': fetchModelInfoFromHub,
  };

  /// Unknown, missing or wrongly typed values fall back to the defaults, so older or damaged
  /// saves keep loading (one bad value must not reset everything else).
  factory AppSettings.fromJson(Map<String, Object?> json) {
    const d = AppSettings();
    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key]! as bool : fallback;
    int whole(String key, int fallback) =>
        json[key] is num ? (json[key]! as num).toInt() : fallback;
    String text(String key, String fallback) =>
        json[key] is String ? json[key]! as String : fallback;
    double decimal(String key, double fallback) =>
        json[key] is num ? (json[key]! as num).toDouble() : fallback;
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
      speedAccuracy: json['speedAccuracy'] is num
          ? (json['speedAccuracy']! as num).toDouble()
          : d.speedAccuracy,
      hyperLoad: flag('hyperLoad', d.hyperLoad),
      theme: option(ThemeMode.values, 'theme', d.theme),
      thinkingStyle: option(
        ThinkingStyle.values,
        'thinkingStyle',
        d.thinkingStyle,
      ),
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
      autoInstallUpdate: flag('autoInstallUpdate', d.autoInstallUpdate),
      updateIntervalHours: whole('updateIntervalHours', d.updateIntervalHours),
      localTemperature: decimal('localTemperature', d.localTemperature),
      localTopP: decimal('localTopP', d.localTopP),
      localTopK: whole('localTopK', d.localTopK),
      localMinP: decimal('localMinP', d.localMinP),
      localMaxTokens: whole('localMaxTokens', d.localMaxTokens),
      localPrompt: text('localPrompt', d.localPrompt),
      onlineTemperature: decimal('onlineTemperature', d.onlineTemperature),
      onlineTopP: decimal('onlineTopP', d.onlineTopP),
      onlineMaxTokens: whole('onlineMaxTokens', d.onlineMaxTokens),
      onlinePrompt: text('onlinePrompt', d.onlinePrompt),
      codingPlanEnabled: flag('codingPlanEnabled', d.codingPlanEnabled),
      plannerModel: text('plannerModel', d.plannerModel),
      developerModel: text('developerModel', d.developerModel),
      codingMaxTasks: whole('codingMaxTasks', d.codingMaxTasks),
      codingParallel: whole('codingParallel', d.codingParallel),
      codingReviewRounds: whole('codingReviewRounds', d.codingReviewRounds),
      // 0.8.1 saved its fixed defaults (2048 / 4096) with every settings write; they were never a
      // choice, and they are far too small for a reasoning model, so they mean "decide" now
      codingPlannerMaxTokens: whole('codingPlannerMaxTokens', d.codingPlannerMaxTokens) == 2048
          ? 0
          : whole('codingPlannerMaxTokens', d.codingPlannerMaxTokens),
      codingDeveloperMaxTokens: whole('codingDeveloperMaxTokens', d.codingDeveloperMaxTokens) == 4096
          ? 0
          : whole('codingDeveloperMaxTokens', d.codingDeveloperMaxTokens),
      attachMaxFiles: whole('attachMaxFiles', d.attachMaxFiles),
      attachCharsPerFile: whole('attachCharsPerFile', d.attachCharsPerFile),
      attachTotalChars: whole('attachTotalChars', d.attachTotalChars),
      attachImageMb: whole('attachImageMb', d.attachImageMb),
      searchResultCount: whole('searchResultCount', d.searchResultCount),
      httpTimeoutSeconds: whole('httpTimeoutSeconds', d.httpTimeoutSeconds),
      mcpTimeoutSeconds: whole('mcpTimeoutSeconds', d.mcpTimeoutSeconds),
      providerTimeoutSeconds: whole('providerTimeoutSeconds', d.providerTimeoutSeconds),
      toolRepeatLimit: whole('toolRepeatLimit', d.toolRepeatLimit),
      updateRetryAttempts: whole('updateRetryAttempts', d.updateRetryAttempts),
      updateStallSeconds: whole('updateStallSeconds', d.updateStallSeconds),
      localDryMultiplier: decimal('localDryMultiplier', d.localDryMultiplier),
      kvSnapshotEnabled: flag('kvSnapshotEnabled', d.kvSnapshotEnabled),
      kvSnapshotMaxMb: whole('kvSnapshotMaxMb', d.kvSnapshotMaxMb),
      kvSnapshotMinTokens: whole('kvSnapshotMinTokens', d.kvSnapshotMinTokens),
      autoFetchModelInfo: flag('autoFetchModelInfo', d.autoFetchModelInfo),
      fetchModelInfoFromHub: flag('fetchModelInfoFromHub', d.fetchModelInfoFromHub),
      searchApis: SearchApis.decode(json['searchApis']),
      // a save from before multiple servers keeps its one endpoint
      mcpServers: (() {
        final parsed = McpServers.decode(json['mcpServers']);
        if (parsed.isNotEmpty) return parsed;
        final url = text('mcpUrl', '');
        if (url.trim().isEmpty) return const <McpServerConfig>[];
        return [
          McpServerConfig(
            id: 'default',
            name: 'MCP',
            url: url.trim(),
            enabled: flag('mcpEnabled', false),
          ),
        ];
      })(),
    );
  }

  /// The settings of one generation. [cloud] picks the online model settings instead of the
  /// device model's: the two are separate, so a change to one never touches the other.
  GenerationSettings toGeneration(double? modelParamsB, {bool cloud = false}) => GenerationSettings(
    tone: tone.trim().isEmpty ? null : tone,
    maxChars: maxChars,
    maxTokens: (cloud ? onlineMaxTokens : localMaxTokens) > 0
        ? (cloud ? onlineMaxTokens : localMaxTokens)
        : maxTokens,
    temperature: _set(cloud ? onlineTemperature : localTemperature),
    topP: _set(cloud ? onlineTopP : localTopP),
    // top-k and min-p are the device engine's; a provider takes only temperature and top-p
    topK: cloud || localTopK <= 0 ? null : localTopK,
    minP: cloud ? null : _set(localMinP),
    extraPrompt: (cloud ? onlinePrompt : localPrompt).trim(),
    dryMultiplier: cloud ? null : _set(localDryMultiplier),
    userMaxTokens: (cloud ? onlineMaxTokens : localMaxTokens) > 0 ? (cloud ? onlineMaxTokens : localMaxTokens) : null,
    toolRepeatLimit: toolRepeatLimit.clamp(2, 10),
    attachments: attachmentLimits,
    searchEnabled: searchEnabled,
    retryLimit: retryLimit,
    maxToolRounds: maxToolRounds,
    speedAccuracy: speedAccuracy,
    modelParamsB: modelParamsB,
    agentOverride: agentOverride.isEmpty ? null : agentOverride,
    aiAgentSelection: aiAgentSelection,
  );

  static double? _set(double value) => value < 0 ? null : value;

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
  SettingsStore(this._prefs, {FlutterSecureStorage? secure})
    : _secure =
          secure ??
          // the legacy keychain needs no entitlement or provisioning profile, so unsigned builds can use it
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  static const _key = 'settings.v1';
  static const _tokenKey = 'github_token';
  static const _legacyBraveKey = 'brave_api_key'; // 0.8.6, before the search services were a list
  static const _mcpTokenKey =
      'mcp_token'; // one server, before the list existed

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  AppSettings _value = const AppSettings();
  AppSettings get value => _value;

  String _token = '';

  /// Empty when none is set (or secure storage is unavailable on this system).
  String get githubToken => _token;

  final Map<String, String> _searchKeys = {};

  /// The key of the search service [id]; empty when none is set. Kept in the secure storage only.
  String searchKeyOf(String id) => _searchKeys[id] ?? '';

  final Map<String, String> _mcpTokens = {};

  /// The bearer token of [id]; empty when none is set.
  String mcpTokenOf(String id) => _mcpTokens[id] ?? '';

  /// Kept for a save from before multiple servers.
  String get mcpToken => mcpTokenOf('default');

  static Future<SettingsStore> load({FlutterSecureStorage? secure}) async {
    final store = SettingsStore(
      await SharedPreferences.getInstance(),
      secure: secure,
    );
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
      for (final api in store._value.searchApis) {
        store._searchKeys[api.id] = await store._secure.read(key: api.keyRef) ?? '';
      }
      await store._migrateBraveKey();
      final legacy = await store._secure.read(key: _mcpTokenKey) ?? '';
      for (final server in store._value.mcpServers) {
        store._mcpTokens[server.id] =
            await store._secure.read(key: server.tokenRef) ?? '';
      }
      if (legacy.isNotEmpty &&
          store.mcpTokenOf('default').isEmpty &&
          store._value.mcpServers.any((s) => s.id == 'default')) {
        store._mcpTokens['default'] = legacy;
        await store._secure.write(
          key: store._value.mcpServers
              .firstWhere((s) => s.id == 'default')
              .tokenRef,
          value: legacy,
        );
      }
    } catch (_) {
      store._token = '';
      store._searchKeys.clear();
      store._mcpTokens.clear();
    }
    return store;
  }

  Future<void> update(AppSettings Function(AppSettings) change) async {
    _value = change(_value);
    notifyListeners();
    await _prefs.setString(_key, jsonEncode(_value.toJson()));
  }

  Future<void> setMcpToken(String id, String token) async {
    _mcpTokens[id] = token.trim();
    notifyListeners();
    try {
      final ref = McpServerConfig(id: id, name: '', url: '').tokenRef;
      if (token.trim().isEmpty) {
        await _secure.delete(key: ref);
      } else {
        await _secure.write(key: ref, value: token.trim());
      }
    } catch (_) {
      // keep the token for this run only when the system keyring is missing
    }
  }

  /// Removes the token of a server that was deleted.
  Future<void> forgetMcpToken(String id) async {
    _mcpTokens.remove(id);
    notifyListeners();
    try {
      await _secure.delete(
        key: McpServerConfig(id: id, name: '', url: '').tokenRef,
      );
    } catch (_) {
      // nothing was stored
    }
  }

  Future<void> setSearchKey(String id, String key) async {
    _searchKeys[id] = key.trim();
    notifyListeners();
    try {
      final ref = SearchApiConfig(id: id, name: '', url: '').keyRef;
      if (key.trim().isEmpty) {
        await _secure.delete(key: ref);
      } else {
        await _secure.write(key: ref, value: key.trim());
      }
    } catch (_) {
      // keep the key for this run only when the system keyring is missing
    }
  }

  /// Removes the key of a search service that was deleted.
  Future<void> forgetSearchKey(String id) async {
    _searchKeys.remove(id);
    notifyListeners();
    try {
      await _secure.delete(key: SearchApiConfig(id: id, name: '', url: '').keyRef);
    } catch (_) {
      // nothing was stored
    }
  }

  /// 0.8.6 kept one Brave key of its own; it becomes the first entry of the list.
  Future<void> _migrateBraveKey() async {
    final legacy = await _secure.read(key: _legacyBraveKey) ?? '';
    if (legacy.isEmpty) return;
    if (!_value.searchApis.any((a) => a.id == 'brave-search')) {
      final preset = SearchApiConfig.presets['Brave Search']!;
      _value = _value.copyWith(searchApis: [..._value.searchApis, SearchApiConfig.fromJson({...preset.toJson(), 'id': 'brave-search'})]);
      await _prefs.setString(_key, jsonEncode(_value.toJson()));
    }
    if (searchKeyOf('brave-search').isEmpty) {
      _searchKeys['brave-search'] = legacy;
      await _secure.write(key: SearchApiConfig(id: 'brave-search', name: '', url: '').keyRef, value: legacy);
    }
    await _secure.delete(key: _legacyBraveKey);
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
