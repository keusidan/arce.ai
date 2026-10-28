import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, WidgetsFlutterBinding;

import '../ai/cloud_engine.dart';
import '../ai/model_info.dart';
import '../ai/openai_compatible.dart';
import '../ai/delegation.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';
import '../ai/roles.dart';
import '../ai/routing_engine.dart';
import '../ai/titles.dart';
import '../core/agents.dart';
import '../core/error_report.dart';
import '../core/chat_controller.dart';
import '../core/coding_plan.dart';
import '../core/engine.dart';
import '../core/generation.dart';
import '../core/http_get.dart';
import '../core/protocol.dart';
import '../core/run_progress.dart';
import '../core/search.dart';
import '../core/settings_spec.dart';
import '../core/tool_runtime.dart';
import '../core/weather.dart';
import '../engine/demo_engine.dart';
import '../mcp/mcp_client.dart';
import '../mcp/mcp_server.dart';
import '../mcp/mcp_tools.dart';
import '../engine/hybrid_engine.dart';
import '../engine/native_engine.dart';
import 'conversation_database.dart';
import 'conversation_search.dart';
import 'device_info.dart';
import 'error_reporter.dart';
import 'linux_env.dart';
import 'model_info_fetcher.dart';
import 'foreground_service.dart';
import 'kv_snapshots.dart';
import 'model_manager.dart';
import 'preview_server.dart';
import 'chat_handle.dart';
import 'provider_store.dart';
import 'session_engine.dart';
import 'settings.dart';
import 'update_service.dart';

enum AppPage { chat, models, artifacts, settings, history }

/// Anchors of the sections of the settings page, so the desktop sidebar can jump to one.
enum SettingsSection {
  providers,
  online,
  local,
  coding,
  shell,
  limits,
  mcp,
  basic,
  search,
  display,
  update,
  reports,
}

/// A generation that was still running when the app last stopped (spec §25.1).
class InterruptedConversation {
  const InterruptedConversation(this.id, this.title);
  final String id;
  final String title;
}

/// Application-wide objects. The chat and the loaded model live here rather than in a page,
/// so a generation survives switching pages.
class AppController extends ChangeNotifier {
  AppController._({
    required this.settings,
    required this.providers,
    required this.history,
    required this.models,
    required this.updates,
    required this.foreground,
    required this.device,
    required this.cloud,
    required this.engine,
    required this.preview,
    required this.errors,
    required this.linux,
  }) {
    _current = _newSession();
    chat = ChatHandle(_current.chat);
    chat.addListener(_syncForeground);
    _applyProvider();
  }

  /// A chat of its own: its controller, its engine (see [SessionEngine]) and, once it is saved, the
  /// id of its conversation. The one on the screen is [_current]; the others that are still
  /// generating are in [_background].
  _Session _newSession() {
    final session = _Session();
    final stop = StopSignal();
    final meter = RunMeter();
    session.chat = ChatController(
      SessionEngine(engine, _lease),
      stopSignal: stop,
      meter: meter,
      delegateEnabled: _delegateAvailable,
      onFailure: (reason) => reportProblem('chat', reason),
      delegateInstructions: () {
        final s = settings.value.coding;
        return CodingPrompts.plannerInstructions(maxTasks: s.maxTasks, reviewRounds: s.reviewRounds);
      },
      toolRuntime: _SessionToolRuntime(_toolRuntime, _delegate, stop, _lease, meter),
      settings: () => settings.value.toGeneration(
        models.loadedParamsB,
        cloud: engine.isCloud,
      ),
      store: (snapshot, {required generating}) => _persist(session, snapshot, generating),
      extraTools: _mcpDefinitions,
      applySettings: _applySettings,
      addProvider: _addProvider,
      mcpApproval: _mcpApprovalRequired,
    )..setThinking(settings.value.thinking);
    session.chat.addListener(_syncForeground);
    return session;
  }

  String _lastRunning = '';
  final _lease = ExclusiveLease();
  late _Session _current;
  final _background = <_Session>[];

  Iterable<_Session> get _sessions => [_current, ..._background];

  bool get _anyGenerating => _sessions.any((s) => s.chat.isRunning);

  /// The conversation on the screen; null for a new one that has not been saved yet.
  String? get conversationId => _current.id;

  /// Whether conversation [id] is being answered now (on the screen or in the background).
  bool isRunning(String id) => _sessions.any((s) => s.id == id && s.chat.isRunning);

  /// Puts the session that is on the screen aside if it is still generating (it goes on in the
  /// background), and returns the session to fill: the same one when it was idle.
  _Session _freeCurrent() {
    if (_current.chat.isRunning) {
      _background.add(_current);
      _current = _newSession();
    }
    return _current;
  }

  /// Ends a background session that has finished: its conversation is saved, nothing is left to run.
  void _reapBackground() {
    final done = _background.where((s) => !s.chat.isRunning).toList();
    for (final session in done) {
      _background.remove(session);
      // not inside its own notification
      Timer.run(() {
        session.chat.removeListener(_syncForeground);
        session.chat.dispose();
      });
    }
  }

  final SettingsStore settings;

  /// The providers the user added, and the one in use (device model or one of them).
  final ProviderStore providers;
  final ConversationDatabase history;
  final ModelManager models;
  final UpdateService updates;
  final DeviceInfoService device;

  /// The cloud side of the router; its provider is replaced when the user picks another one.
  final CloudEngine cloud;

  /// Sends each request to the device model or to the chosen provider.
  final RoutingEngine engine;
  final PreviewServer preview;

  /// Sends the errors to a GitHub issue (settings: エラーの報告).
  final ErrorReporter errors;

  /// The Linux environment on the device (docs 15 and 19.5): whether it is installed, installing
  /// it, and its state for the settings screen. The tool itself runs through [McpTools].
  final LinuxEnvironment linux;

  /// Shared with [updates]: a download keeps running when another app is in front.
  final ForegroundService foreground;
  late final ChatHandle chat;

  /// Whether the model that answers takes images, so attached pictures are read as pictures.
  /// The device model never does: it reads text only.
  bool get acceptsImages => engine.cloudProvider?.capabilities.vision ?? false;

  AppPage page = AppPage.chat;

  /// Finds out what an online model can do (its limits, whether it sees images).
  final modelInfo = ModelInfoFetcher();

  /// The models already asked about in this run, so each is asked once.
  final _modelInfoAsked = <String>{};

  /// Saves the device model's KV cache of a conversation to a file; null where the engine cannot.
  KvSnapshotService? _kv;

  /// The conversation whose prompt the engine's KV cache holds, set when the device model has
  /// answered in it.
  String? _kvOwner;
  AppLifecycleListener? _lifecycle;

  /// Which part of the settings page to scroll to (set by the desktop sidebar).
  final settingsSection = ValueNotifier<SettingsSection?>(null);

  /// Whether the desktop sidebar is shown (the hamburger button toggles it).
  final sidebarOpen = ValueNotifier<bool>(true);
  InterruptedConversation? interrupted;
  List<ConversationMeta> conversations = const [];

  /// Text shown briefly at the bottom of the screen.
  final toast = ValueNotifier<String?>(null);
  Timer? _toastTimer;

  /// [supportDirectory] replaces the platform's app-data folder (tests use a temporary one).
  static Future<AppController> create({
    Directory? supportDirectory,
    UpdateService? updateService,
    http.Client? reportClient,
    LinuxEnvironment? linux,
  }) async {
    final settings = await SettingsStore.load();
    final providers = await ProviderStore.load();
    final device = DeviceInfoService();
    final native = NativeEngine();
    final foreground = ForegroundService();
    final models = await ModelManager.create(
      engine: native,
      settings: settings,
      device: device,
      foreground: foreground,
      supportDirectory: supportDirectory,
    );
    final history = await ConversationDatabase.open(
      supportDirectory: supportDirectory,
    );
    final updates = updateService ?? UpdateService(settings, foreground: foreground);
    final cloud = CloudEngine(const _NoProvider());
    final app = AppController._(
      settings: settings,
      providers: providers,
      history: history,
      models: models,
      updates: updates,
      foreground: foreground,
      device: device,
      cloud: cloud,
      // the device model answers until the user picks a provider
      engine: RoutingEngine(
        local: HybridEngine(native, DemoEngine()),
        cloud: cloud,
      ),
      preview: PreviewServer(),
      errors: ErrorReporter(
        client: reportClient,
        prefs: await SharedPreferences.getInstance(),
        config: () => ErrorReportConfig(
          enabled: settings.value.errorReportEnabled,
          repo: settings.value.errorReportRepo,
          token: settings.issueToken,
          minHours: settings.value.errorReportMinHours,
          maxPerHour: settings.value.errorReportMaxPerHour,
        ),
      ),
      // the same environment the tool runs in, so the settings screen shows its real state
      linux: linux ?? McpTools.shell,
    );
    final local = app.engine.local;
    if (local is KvStatePersistence) {
      app._kv = KvSnapshotService(
        database: history,
        engine: local as KvStatePersistence,
        config: () => settings.value.kvSnapshot,
      );
    }
    app.engine.planner = app._plannerEngine;
    unawaited(app._start());
    return app;
  }

  late final _http = packageHttpGet(
    timeoutOf: () => Duration(seconds: settings.value.httpTimeoutSeconds.clamp(3, 300)),
  );

  late final _httpPost = packageHttpPost(
    timeoutOf: () => Duration(seconds: settings.value.httpTimeoutSeconds.clamp(3, 300)),
  );

  /// Built per call so a changed SearXNG address or search switch applies immediately.
  late final ToolRuntime _toolRuntime = _SettingsToolRuntime(
    settings,
    providers,
    _http,
    _httpPost,
  );

  /// Applies the settings the user approved in the chat (protocol `update_settings`). The reply
  /// says what the settings are now, so the model can confirm instead of assuming.
  Future<String> _applySettings(List<SettingsChangeOk> changes) async {
    await settings.update((current) => withSettings(current, changes));
    final values = settings.value.toJson();
    final now = [
      for (final change in changes)
        '${change.key}=${change.spec.format(values[change.key])}',
    ].join(', ');
    final reload = changes.any((c) => _reloadNeeded.contains(c.key));
    return 'The user approved the change: $now.'
        '${reload ? ' It takes effect the next time the model is loaded.' : ''}';
  }

  /// Saves the provider the user approved in the chat (protocol `add_provider`). It is always a new
  /// entry with a new id, so no existing provider (and no key kept for it) is touched, and it is not
  /// made the active one. The key is typed on the settings screen.
  Future<String> _addProvider(ProviderDraft draft) async {
    final config = ProviderConfig(
      id: ProviderList.idFor(draft.name, providers.providers),
      label: draft.name,
      baseUrl: draft.baseUrl,
      models: [for (final id in draft.models) ModelConfig(id: id, name: id)],
      supportsTools: draft.supportsTools,
    );
    await providers.save(config);
    return 'The user approved it and the provider "${config.label}" (id=${config.id}) was added with '
        'the models ${draft.models.join(', ')}. It has no API key yet and is not in use. Tell the user to '
        'open the settings screen, choose the provider, type the API key there, and then pick it in '
        'the model menu.';
  }

  /// Settings a running model keeps until it is loaded again.
  static const _reloadNeeded = {
    'contextLength',
    'threads',
    'batchSize',
    'gpuOffload',
  };

  /// `tools/list` results, kept per server so a chat turn does not ask every server again.
  final Map<String, List<McpTool>> _mcpCache = {};

  /// The enabled servers with an http(s) URL, built per use so a changed setting applies at once.
  List<McpServerClient> _mcpServerClients() => [
    for (final server in settings.value.mcpServers)
      if (server.enabled &&
          (server.url.trim().startsWith('http://') ||
              server.url.trim().startsWith('https://')))
        McpServerClient(
          server,
          McpClient(
            url: server.url.trim(),
            token: settings.mcpTokenOf(server.id),
            timeout: Duration(seconds: settings.value.mcpTimeoutSeconds.clamp(5, 600)),
            maxResultChars: settings.value.mcpResultMaxChars,
          ),
        ),
  ];

  /// The GitHub token `ci_status` reads with: the one kept for the GitHub server, so the tool needs
  /// no key of its own (empty: the public API, which answers for a public repository).
  String get _ciToken {
    for (final server in settings.value.mcpServers) {
      final id = server.id.toLowerCase();
      final name = server.name.toLowerCase();
      if (id == 'github' ||
          name == 'github' ||
          server.url.contains('githubcopilot.com') ||
          server.url.contains('api.github.com')) {
        return settings.mcpTokenOf(server.id);
      }
    }
    return '';
  }

  /// What the Linux environment's settings say now, asked on every use so a change applies to the
  /// next command (docs 19.5).
  ShellSettings get _shellSettings {
    final s = settings.value;
    return ShellSettings(
      enabled: s.shellEnabled,
      confirm: s.shellConfirm,
      timeoutSeconds: s.shellTimeoutSeconds,
      maxTimeoutSeconds: s.shellMaxTimeoutSeconds,
      maxOutputChars: s.shellMaxOutputChars,
      workspaceLimitMb: s.workspaceLimitMb,
      rootfsUrl: s.linuxRootfsUrl,
      rootfsSha256: s.linuxRootfsSha256,
      dns: s.linuxDns,
      compatMode: s.shellCompatMode,
      downloadConnections: s.downloadConnections,
    );
  }

  /// What the settings screen needs to install, remove and measure the environment.
  LinuxConfig get linuxConfig => _shellSettings.config;

  /// Reads the environment's state from the Android side (what the settings screen shows).
  Future<void> refreshLinux() async {
    if (!LinuxEnvironment.supported) return;
    try {
      await linux.refresh(linuxConfig);
    } catch (e) {
      debugPrint('could not read the Linux environment: $e');
    }
  }

  /// Downloads and unpacks the root file system, as the settings screen asks.
  Future<void> installLinux() async {
    await linux.refresh(linuxConfig);
    if (linux.ready) return;
    await linux.install(linuxConfig);
  }

  /// Removes the root file system; the shared workspace stays.
  Future<void> removeLinux() async {
    await linux.remove();
    notifyListeners();
  }

  /// Empties the workspace every chat shares.
  Future<void> clearLinuxWorkspace() async {
    await linux.clearWorkspace(linuxConfig);
    notifyListeners();
  }

  McpTools get _mcpTools => McpTools(
    _mcpServerClients(),
    cache: _mcpCache,
    ciToken: _ciToken,
    shell: _shellSettings,
  );

  /// The tools of every MCP server, added to the ones the agent already has.
  Future<List<ToolDefinition>> _mcpDefinitions() => _mcpTools.definitions();

  /// Whether an MCP tool should wait for the user; a server can turn this off for itself.
  bool _mcpApprovalRequired(String name) => _mcpTools.approvalRequired(name);

  /// Used by the settings screen: asks one server what it offers and says so, with what its tools
  /// add to every request, and a warning when that is more than the model in use can take.
  Future<String> probeMcp(String id) async {
    final tools = _mcpTools;
    final text = await tools.describe(id);
    final tokens = await tools.overheadTokens(id);
    final context = providers.activeModel?.contextTokens;
    if (tokens == null || context == null) return text;
    final ratio = settings.value.tokenOverheadPercent / 100;
    if (tokens > context * ratio) {
      return '$text\n注意: 使用中のモデル（${providers.activeModelId}）の文脈 $context トークンに対して、'
          'ツール定義だけで約 $tokens トークンです。このままでは送る前にエラーになります';
    }
    if (tokens > context * 0.4) {
      return '$text\n注意: ツール定義が、使用中のモデルの文脈の ${(tokens * 100 / context).round()}% を使います';
    }
    return text;
  }

  /// Runs one search with the values of the editor (saved or not) and says what came back.
  Future<String> testSearchApi(SearchApiConfig config, String key) async {
    final problem = config.problem;
    if (problem != null) return problem;
    try {
      final hits = await ConfiguredSearchProvider(config, key, _http, post: _httpPost).search('test', 3);
      return hits.isEmpty
          ? '接続できましたが、結果を読み取れませんでした（結果のパスと項目名を確かめてください）'
          : '${hits.length} 件読み取れました: ${hits.first.title}';
    } catch (e) {
      return '失敗: $e';
    }
  }

  /// What the report says about the setting it happened in: the version, the system, who was
  /// answering (the device or an online model: its host and its model name). Nothing of the
  /// conversation, and no key.
  Map<String, String> errorFacts() {
    final config = providers.active;
    final host = config == null ? '' : (Uri.tryParse(config.baseUrl.trim())?.host ?? '');
    return {
      'app': '${updates.currentVersion ?? ''}',
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'engine': config == null ? 'device' : 'online',
      if (host.isNotEmpty) 'provider host': host,
      if (config != null) 'model': providers.activeModelId,
    };
  }

  /// Reports an error to the GitHub issue, if it is the kind that is the app's to fix (see
  /// [ErrorPolicy]), the setting is on and a token is set. It runs in the background and never fails.
  void reportProblem(String kind, String message, {Object? error, StackTrace? stack}) {
    try {
      if (!ErrorPolicy.shouldReport(kind, '$message ${error ?? ''}')) return;
      final report = ErrorReport.of(kind: kind, message: message, error: error, stack: stack, facts: errorFacts());
      unawaited(errors.report(report));
    } catch (e) {
      debugPrint('could not report an error: $e');
    }
  }

  Future<void> _start() async {
    // reports that waited for the network go out now
    unawaited(errors.flush());
    // a model download that the app was closed in the middle of carries on (a setting)
    if (settings.value.resumeDownloadsOnStart) {
      models.resumeInterrupted();
    } else {
      models.interrupted.clear();
    }
    settings.addListener(() {
      for (final session in _sessions) {
        session.chat.setThinking(settings.value.thinking);
      }
    });
    // adding, removing or editing a provider changes which one answers
    providers.addListener(_applyProvider);
    // the app going to the background may end with the system closing it: keep the cache now
    try {
      WidgetsFlutterBinding.ensureInitialized();
      _lifecycle = AppLifecycleListener(onPause: () => unawaited(_saveKv()));
    } catch (e) {
      debugPrint('no lifecycle events: $e');
    }
    // a changed timeout reaches the provider in use by building it again
    var timeout = settings.value.providerTimeoutSeconds;
    settings.addListener(() {
      _applyEngineSettings();
      if (settings.value.providerTimeoutSeconds == timeout) return;
      timeout = settings.value.providerTimeoutSeconds;
      _applyProvider();
    });
    _applyEngineSettings();
    // what the settings screen shows about the Linux environment (its size, whether it is there)
    unawaited(refreshLinux());
    // the model lists that are missing or old are read in the background
    unawaited(autoReadModelLists().catchError((Object e) => debugPrint('could not read the model lists: $e')));
    try {
      await refreshConversations();
      final item = conversations.where((c) => c.generating).firstOrNull;
      if (item != null) {
        interrupted = InterruptedConversation(item.id, item.title);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('could not read the conversation list: $e');
    }
    unawaited(
      updates.init().catchError(
        (Object e) => debugPrint('update check setup failed: $e'),
      ),
    );
    unawaited(
      models.restoreLastModel().catchError(
        (Object e) => debugPrint('could not restore the last model: $e'),
      ),
    );
  }

  /// Carries out the planner's `delegate` calls with the developer model (see [DelegateRunner]).
  late final _delegate = DelegateRunner(
    settings: () => settings.value.coding,
    developer: () => _roleFor(settings.value.coding.developer),
  );

  /// Whether the coding mode can work now: it is on, and both the planner and the developer model
  /// can be used. Only then is the `delegate` tool offered and the planner the one that answers.
  bool _delegateAvailable() {
    final s = settings.value.coding;
    return s.isReady && _roleFor(s.developer, note: false) != null && _plannerEngine(null, note: false) != null;
  }

  /// The engine of the planner model for [request], or null when the model in use answers: the
  /// coding mode is off or not ready, or the request is not the coding agent's.
  InferenceEngine? _plannerEngine(GenerateRequest? request, {bool note = true}) {
    final s = settings.value.coding;
    if (!s.isReady) return null;
    if (request != null && request.agentId != Agents.coding.id) return null;
    if (_roleFor(s.developer, note: false) == null) return null;
    final parsed = CodingSettings.parseRef(s.planner);
    if (parsed == null) return null;
    final (providerId, modelId) = parsed;
    if (providerId == CodingSettings.localProvider) return models.isLoaded ? engine.local : null;
    final config = providers.byId(providerId);
    if (config == null || !config.isComplete) return null;
    final provider = providers.build(config, model: config.resolveModel(modelId) ?? config.defaultModel);
    final keep = settings.value.recentModelCount;
    if (note && keep > 0) unawaited(providers.markUsed(providerId, provider.modelId, keep: keep));
    final s2 = settings.value;
    // answers like the model in use would: the same bridging, tool style, thinking and stop
    return CloudEngine(provider)
      ..fallbackFor = s2.fallbackEnabled ? providers.fallbackPlanFor : null
      ..onFallback = _announceFallback
      ..tokenPrecheck = s2.tokenPrecheck
      ..overheadRatio = s2.tokenOverheadPercent / 100;
  }

  /// The model behind a `provider|model` reference of the coding mode, or null when it cannot be
  /// used now: the provider was removed or is incomplete, or the device model is not loaded.
  RoleModel? _roleFor(String ref, {bool note = true}) {
    final parsed = CodingSettings.parseRef(ref);
    if (parsed == null) return null;
    final (providerId, modelId) = parsed;
    if (providerId == CodingSettings.localProvider) {
      return models.isLoaded
          ? LocalRole(engine.local, name: models.loadedName ?? '端末のモデル')
          : null;
    }
    final config = providers.byId(providerId);
    if (config == null || !config.isComplete) return null;
    // a model that is only in the provider's catalog works as it is, with what the list says of it
    final provider = providers.build(config, model: config.resolveModel(modelId) ?? config.defaultModel);
    final keep = settings.value.recentModelCount;
    if (note && keep > 0) unawaited(providers.markUsed(providerId, provider.modelId, keep: keep));
    return ProviderRole(
      provider,
      fallback: settings.value.fallbackEnabled ? providers.fallbackPlanFor(provider) : null,
      onFallback: _announceFallback,
    );
  }

  /// Keeps Android's foreground service in step with whether a reply is being generated.
  void _syncForeground() {
    _reapBackground();
    // the history list marks the chats that are answering: tell it when that set changes
    final running = [for (final s in _sessions) if (s.id != null && s.chat.isRunning) s.id!].join(',');
    if (running != _lastRunning) {
      _lastRunning = running;
      notifyListeners();
    }
    if (_anyGenerating) {
      unawaited(foreground.start());
    } else {
      unawaited(foreground.stop());
    }
  }

  /// Points the router at the chosen provider; the device model when none is usable.
  /// Asks the provider (and the Hub) about the model in use when its limits are not known yet, and
  /// keeps the answer with the model. Once per model and run; what the user typed is not replaced.
  Future<void> _autoFillModelInfo() async {
    final config = providers.active;
    final model = providers.activeModel;
    if (!settings.value.autoFetchModelInfo || config == null || model == null) return;
    if (model.contextTokens != null && model.maxOutputTokens != null) return;
    if (!_modelInfoAsked.add('${config.id}|${model.id}')) return;
    try {
      final provider = providers.build(config, model: model);
      if (provider is! OpenAiCompatibleProvider) return;
      final found = await modelInfo.fetchFor(provider, model, useHub: settings.value.fetchModelInfoFromHub);
      if (jsonEncode(found.toJson()) == jsonEncode(model.toJson())) return;
      // the provider may have changed while it was being asked
      final current = providers.byId(config.id);
      if (current == null) return;
      await providers.save(
        current.copyWith(models: [for (final m in current.models) m.id == found.id ? m.mergeInfo(ModelInfo(found.id, contextTokens: found.contextTokens, maxOutputTokens: found.maxOutputTokens, vision: found.vision)) : m]),
      );
    } catch (e) {
      debugPrint('could not look up ${model.id}: $e');
    }
  }

  void _applyProvider() {
    unawaited(_autoFillModelInfo());
    providers.requestTimeout = Duration(seconds: settings.value.providerTimeoutSeconds.clamp(10, 1800));
    final provider = providers.buildActive();
    if (provider != null) cloud.provider = provider;
    engine.target = provider;
    _applyEngineSettings();
    notifyListeners();
  }

  /// What the settings say about the online engine: the fallback rules, and the check of a request
  /// against the model's context before it is sent.
  void _applyEngineSettings() {
    final s = settings.value;
    cloud.fallbackFor = s.fallbackEnabled ? providers.fallbackPlanFor : null;
    cloud.onFallback = _announceFallback;
    cloud.tokenPrecheck = s.tokenPrecheck;
    cloud.overheadRatio = s.tokenOverheadPercent / 100;
  }

  void _announceFallback(AiProvider from, AiProvider to, String reason) {
    showToast('${from.label} · ${from.modelId} が使えないため（$reason）、${to.label} · ${to.modelId} で答えます');
  }

  final _listBusy = <String>{};

  /// True while the model list of provider [id] is being read.
  bool isReadingModelList(String id) => _listBusy.contains(id);

  /// Reads the model list of provider [id] and keeps it as the provider's catalog (the models the
  /// user can pick). The models already set up only gain the limits they lacked. Returns what to
  /// tell the user.
  Future<String> refreshModelList(String id) async {
    final config = providers.byId(id);
    if (config == null) return 'プロバイダが見つかりません';
    if (!(Uri.tryParse(config.baseUrl.trim())?.hasScheme ?? false)) return 'Base URL（https://…）を入れてください';
    if (!_listBusy.add(id)) return 'いま読み込んでいます';
    notifyListeners();
    try {
      final provider = providers.build(config);
      if (provider is! OpenAiCompatibleProvider) return 'このプロバイダはモデル一覧を読めません';
      final infos = await provider.fetchModelInfos();
      final added = await providers.updateCatalog(id, infos);
      final withLimits = infos.where((i) => i.hasLimits).length;
      return '${infos.length} 件のモデルを読み込みました'
          '${(added ?? 0) > 0 ? '（新しく ${added!} 件）' : ''}'
          '${infos.isNotEmpty && withLimits == 0 ? '。この提供元は上限を返しません（モデルの編集の「取得」で Hugging Face から調べられます）' : ''}';
    } on AiProviderException catch (e) {
      return e.message;
    } catch (e) {
      return '取得できませんでした（$e）';
    } finally {
      _listBusy.remove(id);
      notifyListeners();
    }
  }

  /// Reads the model lists that are missing or older than the setting says, one provider at a time.
  /// [only] limits it to one provider, and [force] reads it even when the list is recent (the
  /// provider has just been saved, so its address or key may be new). A failure is not shown: a
  /// provider that has no list, or whose key is not typed yet, simply has none.
  Future<void> autoReadModelLists({String? only, bool force = false}) async {
    final s = settings.value;
    if (!s.modelListAutoFetch) return;
    final maxAge = s.modelListRefreshHours * 3600 * 1000;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final config in providers.providers) {
      if (only != null && config.id != only) continue;
      if (!config.autoFetchModels) continue;
      final at = config.catalogAt;
      if (!force && at != null && now - at < maxAge) continue;
      await refreshModelList(config.id);
    }
  }

  /// Notes that the model in use answers now, for the "recently used" part of the model lists.
  void _noteModelUsed() {
    final keep = settings.value.recentModelCount;
    if (providers.isCloud && keep > 0) {
      unawaited(providers.markUsed(providers.activeId, providers.activeModelId, keep: keep));
    }
  }

  /// True when replies go to a provider outside this device.
  bool get usingCloud => providers.isCloud;

  /// What the chat shows under the composer: who will answer, and whether it leaves the device.
  String get engineLabel {
    final config = providers.active;
    if (config != null) {
      return '${config.label} · ${providers.activeModelId}（外部送信）';
    }
    if (providers.isCloud) return 'プロバイダの設定が未完了です';
    return engine.isLoaded
        ? '${models.loadedName ?? 'ローカルモデル'} · ${models.backend ?? ''}'
        : 'ローカルモデル未接続 · デモ応答のみ';
  }

  /// [ProviderList.localId] goes back to the device model.
  Future<void> setActiveProvider(String id) async {
    if (_anyGenerating) {
      showToast('生成中は切り替えられません');
      return;
    }
    await providers.setActive(id);
    _applyProvider();
    final config = providers.active;
    showToast(config == null ? '端末のモデルで答えます' : '${config.label} で答えます');
  }

  void goTo(AppPage target) {
    if (page == target) return;
    page = target;
    notifyListeners();
  }

  void openSettings(SettingsSection section) {
    goTo(AppPage.settings);
    settingsSection.value = section;
  }

  void showToast(String text) {
    toast.value = text;
    _toastTimer?.cancel();
    _toastTimer = Timer(
      const Duration(milliseconds: 2200),
      () => toast.value = null,
    );
  }

  /// The conversations that match [query] in their title or in any message; all of them, newest
  /// first, when the query is empty.
  List<ConversationHit> searchConversations(String query) {
    return ConversationSearch.find(history, conversations, query);
  }

  Future<void> refreshConversations() async {
    conversations = await history.list();
    notifyListeners();
  }

  void newConversation() {
    unawaited(_saveKv(leaving: true));
    // a chat that is still answering goes on in the background; an idle one is emptied and reused
    final session = _freeCurrent();
    session.id = null;
    session.titled = false;
    session.titleTries = 0;
    session.chat.clear();
    chat.show(session.chat);
    goTo(AppPage.chat);
    notifyListeners();
  }

  Future<void> openConversation(String id) async {
    if (_current.id == id && _current.chat.isRunning) {
      goTo(AppPage.chat);
      return;
    }
    // it is answering in the background: bring that chat to the screen as it is
    final running = _background.where((s) => s.id == id).firstOrNull;
    if (running != null) {
      final old = _current;
      if (old.chat.isRunning) _background.add(old);
      _background.remove(running);
      _current = running;
      chat.show(running.chat);
      if (!old.chat.isRunning) {
        old.chat.removeListener(_syncForeground);
        Timer.run(old.chat.dispose);
      }
      goTo(AppPage.chat);
      notifyListeners();
      return;
    }
    final snapshot = await history.get(id);
    if (snapshot == null) return;
    if (id != _current.id) unawaited(_saveKv(leaving: true));
    final session = _freeCurrent();
    session.chat.restore(snapshot);
    session.id = id;
    session.titled = true; // it has its title already
    chat.show(session.chat);
    goTo(AppPage.chat);
    notifyListeners();
    _restoreKv(id);
  }

  Future<void> deleteConversation(String id) async {
    // a reply still being written for it is stopped first
    for (final session in _sessions.where((s) => s.id == id)) {
      session.chat.stop();
    }
    // its cache is deleted with it; saving it first would be for nothing
    if (_kvOwner == id) _kvOwner = null;
    await history.delete(id);
    _background.removeWhere((s) => s.id == id);
    if (conversationId == id) newConversation();
    await refreshConversations();
  }

  /// The user's choice for an interrupted generation: resume it, regenerate, or discard it.
  Future<void> resolveInterrupted(String action) async {
    final item = interrupted;
    if (item == null) return;
    interrupted = null;
    notifyListeners();
    await history.clearGenerating(item.id);
    if (action == 'discard') {
      await refreshConversations();
      return;
    }
    final snapshot = await history.get(item.id);
    if (snapshot == null) return;
    unawaited(_saveKv(leaving: true));
    final session = _freeCurrent();
    session.chat.restore(snapshot);
    session.id = item.id;
    session.titled = true;
    chat.show(session.chat);
    goTo(AppPage.chat);
    notifyListeners();
    _restoreKv(item.id);
    if (action == 'resume') {
      if (session.chat.state.canContinue) {
        unawaited(session.chat.continueReply());
      } else {
        unawaited(session.chat.regenerate());
      }
    } else {
      unawaited(session.chat.regenerate());
    }
  }

  String? exportConversation() {
    final snapshot = chat.snapshot();
    if (snapshot.messages.isEmpty) return null;
    return snapshot.messages
        .map(
          (m) => '${m.role == Role.user ? '## User' : '## ARCE.AI'}\n${m.text}',
        )
        .join('\n\n');
  }

  // One writer at a time, in order: the first save of a new chat must get its id before the next.
  Future<void> _writer = Future.value();

  /// What a saved KV cache must match: the model in memory and how it was loaded. Null when there
  /// is nothing to save (no llama.cpp model: LiteRT-LM keeps its own cache).
  String? _kvFingerprint() {
    final loaded = models.loadedWith;
    if (loaded == null || models.backend != 'llama.cpp') return null;
    final file = File(loaded.path);
    final int size;
    try {
      size = file.lengthSync();
    } on FileSystemException {
      return null;
    }
    return KvSnapshotService.fingerprint(
      modelName: file.uri.pathSegments.last,
      modelBytes: size,
      contextLength: loaded.contextLength,
      kvCache: loaded.kvCache,
      appVersion: '${updates.currentVersion ?? ''}',
    );
  }

  /// Keeps the engine's cache of the conversation it last worked on. [leaving] is a switch to
  /// another conversation: the cache then belongs to nobody any more.
  Future<void> _saveKv({bool leaving = false}) async {
    final owner = _kvOwner;
    if (leaving) _kvOwner = null;
    final kv = _kv;
    final fingerprint = _kvFingerprint();
    if (kv == null || owner == null || fingerprint == null || !settings.value.kvSnapshotEnabled) return;
    // a running reply is changing the cache; its end saves it
    if (_anyGenerating) return;
    await kv.save(owner, fingerprint);
  }

  /// Gives the engine the saved cache of [id], so its prompt is not evaluated again.
  void _restoreKv(String id) {
    final kv = _kv;
    final fingerprint = _kvFingerprint();
    if (kv == null || fingerprint == null || providers.isCloud || !settings.value.kvSnapshotEnabled) return;
    final seen = chat.state.messages.length;
    unawaited(
      kv
          .restore(
            id,
            fingerprint,
            // once the user has written to the model, loading would only throw that work away
            stillWanted: () => conversationId == id && !_anyGenerating && chat.state.messages.length == seen,
          )
          .then((restored) {
        if (restored) _kvOwner = id;
      }),
    );
  }

  /// Size of the saved caches, for the settings screen.
  int get kvSnapshotBytes => _kv?.totalBytes ?? 0;

  /// Whether this build can save caches at all (the device engine of the Android build).
  bool get canSaveKv => _kv != null && NativeEngine.isSupportedPlatform;

  Future<void> clearKvSnapshots() async {
    await _kv?.clear();
    notifyListeners();
  }

  /// The title of the conversation on the screen: the one the history list shows (a model's, once
  /// it has written one), or what the user first typed while the conversation is new.
  String get currentTitle {
    final id = _current.id;
    if (id != null) {
      for (final meta in conversations) {
        if (meta.id == id && meta.title.trim().isNotEmpty) return meta.title;
      }
    }
    for (final m in chat.state.messages) {
      final text = m.text.trim();
      if (m.role == Role.user && text.isNotEmpty) return text.length > 24 ? '${text.substring(0, 24)}…' : text;
    }
    return '新しい会話';
  }

  /// The provider that writes titles: the one named in the settings, or the online model in use.
  /// Null for the device model, which does not write titles by itself: the request would take the
  /// place of the conversation in its cache, and the next reply would start from the beginning.
  AiProvider? _titleProvider() {
    final ref = settings.value.titleModel.trim();
    if (ref.isEmpty) return providers.buildActive();
    final parsed = CodingSettings.parseRef(ref);
    if (parsed == null) return null;
    final (providerId, modelId) = parsed;
    if (providerId == CodingSettings.localProvider) return null;
    final config = providers.byId(providerId);
    if (config == null || !config.isComplete) return null;
    return providers.build(config, model: config.resolveModel(modelId) ?? config.defaultModel);
  }

  /// Once a new conversation has its first answer, a model writes its title (the setting
  /// `autoTitle`). It is tried twice at most; a failure leaves the first question as the title.
  void _maybeTitle(_Session session, String id, ConversationSnapshot snapshot) {
    final s = settings.value;
    if (session.titled || !s.autoTitle || session.titleTries >= 2) return;
    String? question;
    String? answer;
    for (final m in snapshot.messages) {
      if (m.role == Role.user && question == null && m.text.trim().isNotEmpty) question = m.text;
      if (m.role == Role.assistant && answer == null && m.text.trim().isNotEmpty && m.finish != FinishReason.error) answer = m.text;
    }
    if (question == null || answer == null) return;
    final provider = _titleProvider();
    if (provider == null) return;
    session.titleTries++;
    unawaited(() async {
      final title = await TitleMaker.make(provider, question: question!, answer: answer!, maxChars: s.titleMaxChars);
      if (title == null) return;
      session.titled = true;
      try {
        await history.rename(id, title);
        await refreshConversations();
      } catch (e) {
        debugPrint('could not set the title: $e');
      }
    }());
  }

  void _persist(_Session session, ConversationSnapshot snapshot, bool generating) {
    if (snapshot.messages.isEmpty) return;
    if (generating) _noteModelUsed();
    final providerId = providers.activeId;
    final modelId = providers.activeModelId;
    _writer = _writer.then((_) async {
      try {
        final id = await history.save(
          session.id,
          snapshot,
          generating: generating,
          providerId: providerId,
          modelId: modelId,
        );
        if (session.id == null) {
          session.id = id;
          notifyListeners();
        }
        // the device model has just worked on this conversation: its cache is the one to keep
        if (!generating && !providers.isCloud && models.isLoaded) _kvOwner = id;
        await refreshConversations();
        if (!generating) _maybeTitle(session, id, snapshot);
      } catch (e) {
        debugPrint('could not save the conversation: $e');
      }
    });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _lifecycle?.dispose();
    chat.removeListener(_syncForeground);
    chat.dispose();
    for (final session in _sessions) {
      session.chat.removeListener(_syncForeground);
    }
    unawaited(foreground.stop());
    providers.removeListener(_applyProvider);
    unawaited(preview.dispose());
    updates.dispose();
    super.dispose();
  }
}

/// The tools of one chat. Everything goes to the shared runtime except `delegate`, which needs this
/// chat's stop button (the developer model may work for minutes) and, when the developer is the
/// device model, the device lease.
class _SessionToolRuntime implements ToolRuntime {
  _SessionToolRuntime(this._base, this._delegate, this._stop, this._lease, this._meter);

  final ToolRuntime _base;
  final DelegateRunner _delegate;
  final StopSignal _stop;
  final ExclusiveLease _lease;
  final RunMeter _meter;

  @override
  Future<ToolOutcome> run(ToolCall call) {
    if (call is Delegate) {
      return _delegate.run(
        call,
        stop: _stop.future,
        acquireDevice: () => _lease.acquire(this),
        releaseDevice: () => _lease.release(this),
        meter: _meter,
      );
    }
    return _base.run(call);
  }
}

/// One chat: the controller that runs it, and the id of its saved conversation (null until it is saved).
class _Session {
  late final ChatController chat;
  String? id;

  /// Whether this conversation has its title (written by a model, or one it already had when opened).
  bool titled = false;
  int titleTries = 0;
}

/// Stands in until the user adds a provider: a request would reach nobody, so it says so.
class _NoProvider implements AiProvider {
  const _NoProvider();

  @override
  String get id => 'none';

  @override
  String get label => '未設定';

  @override
  String get modelId => '';

  @override
  ModelConfig? get modelConfig => null;

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();

  @override
  Stream<Delta> stream(AiRequest request) async* {
    throw const AiProviderException('プロバイダが設定されていません');
  }

  @override
  Future<void> verify() async =>
      throw const AiProviderException('プロバイダが設定されていません');
}

/// Tools read the settings at call time, so a changed SearXNG address or search switch applies at once.
class _SettingsToolRuntime implements ToolRuntime {
  _SettingsToolRuntime(this._settings, this._providers, this._http, this._httpPost);

  final SettingsStore _settings;
  final ProviderStore _providers;
  final HttpGet _http;
  final HttpPost _httpPost;

  @override
  Future<ToolOutcome> run(call) {
    if (call is McpCall) {
      final servers = [
        for (final server in _settings.value.mcpServers)
          if (server.enabled &&
              (server.url.trim().startsWith('http://') ||
                  server.url.trim().startsWith('https://')))
            McpServerClient(
              server,
              McpClient(
                url: server.url.trim(),
                token: _settings.mcpTokenOf(server.id),
                timeout: Duration(seconds: _settings.value.mcpTimeoutSeconds.clamp(5, 600)),
                maxResultChars: _settings.value.mcpResultMaxChars,
              ),
            ),
      ];
      final s0 = _settings.value;
      return McpTools(
        servers,
        shell: ShellSettings(
          enabled: s0.shellEnabled,
          confirm: s0.shellConfirm,
          timeoutSeconds: s0.shellTimeoutSeconds,
          maxTimeoutSeconds: s0.shellMaxTimeoutSeconds,
          maxOutputChars: s0.shellMaxOutputChars,
          workspaceLimitMb: s0.workspaceLimitMb,
          rootfsUrl: s0.linuxRootfsUrl,
          rootfsSha256: s0.linuxRootfsSha256,
          dns: s0.linuxDns,
          compatMode: s0.shellCompatMode,
          downloadConnections: s0.downloadConnections,
        ),
      ).run(call);
    }
    final s = _settings.value;
    final providers = <SearchProvider>[
      if (s.searxngUrl.trim().isNotEmpty)
        SearXngProvider(s.searxngUrl.trim(), _http),
      for (final api in s.searchApis)
        if (api.enabled) ConfiguredSearchProvider(api, _settings.searchKeyOf(api.id), _http, post: _httpPost),
      DuckDuckGoInstantProvider(_http),
    ];
    // without a search server or a search API, only DuckDuckGo's summaries are left, which answer few questions
    final onlySummaries = s.searxngUrl.trim().isEmpty && !s.searchApis.any((a) => a.enabled);
    return DefaultToolRuntime(
      searchHint: onlySummaries
          ? '検索の設定がありません。設定の「検索 API」か「SearXNG のアドレス」を入れると、普通の検索ができます'
          : null,
      search: s.searchEnabled
          ? SearchService(
              providers,
              retriesPerProvider: s.retryLimit.clamp(0, 3),
              limit: s.searchResultCount.clamp(1, 20),
            )
          : null,
      weather: OpenMeteoWeather(_http),
      settingsValues: () => _settings.value.toJson(),
      extraSettings: _describeConfiguration,
    ).run(call);
  }

  /// Providers and MCP servers for `get_settings`: enough to answer questions about them, with
  /// no key and no token.
  String _describeConfiguration() {
    final b = StringBuffer('プロバイダとモデル（追加は add_provider、編集は設定画面）:\n');
    final providers = _providers.providers;
    if (providers.isEmpty) {
      b.write('- （なし。端末のモデルで答えます）\n');
    } else {
      b.write('- 端末のモデル = ${_providers.isCloud ? '使用していません' : '使用中'}\n');
      for (final provider in providers) {
        b.write(
          '- ${provider.label.isEmpty ? provider.id : provider.label} (id=${provider.id})'
          ' = ${provider.baseUrl}、モデル: ${provider.models.map((m) => m.id).join(', ')}'
          '${provider.models.isEmpty ? '（未追加）' : ''}'
          '、APIキー: ${_providers.hasKey(provider.id) ? '設定済み' : '未設定'}',
        );
        if (_providers.activeId == provider.id) {
          b.write('、使用中（モデル ${_providers.activeModelId}）');
        }
        b.write('\n');
      }
    }
    b.write('MCP サーバー（設定画面から追加・編集できます）:\n');
    final servers = _settings.value.mcpServers;
    if (servers.isEmpty) {
      b.write('- （なし）\n');
    } else {
      for (final server in servers) {
        b.write(
          '- ${server.name.isEmpty ? server.id : server.name} (id=${server.id})'
          ' = ${server.url}、${server.enabled ? '有効' : '無効'}'
          '、書き込み前の確認: ${server.approveWrites ? 'あり' : 'なし'}'
          '、トークン: ${_settings.mcpTokenOf(server.id).isEmpty ? '未設定' : '設定済み'}\n',
        );
      }
    }
    b.write('検索 API（設定画面から追加・編集できます）:\n');
    final apis = _settings.value.searchApis;
    if (apis.isEmpty) {
      b.write('- （なし。SearXNG のアドレス: ${_settings.value.searxngUrl.trim().isEmpty ? '未設定' : _settings.value.searxngUrl.trim()}）\n');
    } else {
      for (final api in apis) {
        b.write(
          '- ${api.name.isEmpty ? api.id : api.name} (id=${api.id}) = ${api.url.split('?').first}、${api.enabled ? '有効' : '無効'}'
          '${api.needsKey ? '、APIキー: ${_settings.searchKeyOf(api.id).isEmpty ? '未設定' : '設定済み'}' : ''}\n',
        );
      }
    }
    b.write('APIキー・MCPトークン・検索のキーは、このツールでも設定画面でも読み出せません（チャットからは変更もできません）。');
    return b.toString();
  }
}
