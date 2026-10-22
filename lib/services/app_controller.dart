import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, WidgetsFlutterBinding;

import '../ai/cloud_engine.dart';
import '../ai/coding_engine.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';
import '../ai/routing_engine.dart';
import '../core/chat_controller.dart';
import '../core/coding_plan.dart';
import '../core/engine.dart';
import '../core/http_get.dart';
import '../core/protocol.dart';
import '../core/search.dart';
import '../core/settings_spec.dart';
import '../core/tool_runtime.dart';
import '../core/weather.dart';
import '../engine/demo_engine.dart';
import '../mcp/mcp_client.dart';
import '../mcp/mcp_tools.dart';
import '../engine/hybrid_engine.dart';
import '../engine/native_engine.dart';
import 'conversation_database.dart';
import 'conversation_search.dart';
import 'device_info.dart';
import 'foreground_service.dart';
import 'kv_snapshots.dart';
import 'model_manager.dart';
import 'preview_server.dart';
import 'provider_store.dart';
import 'settings.dart';
import 'update_service.dart';

enum AppPage { chat, models, artifacts, settings, history }

/// Anchors of the sections of the settings page, so the desktop sidebar can jump to one.
enum SettingsSection {
  providers,
  online,
  local,
  coding,
  limits,
  mcp,
  basic,
  answer,
  display,
  developer,
  update,
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
  }) {
    chat = ChatController(
      engine,
      toolRuntime: _toolRuntime,
      settings: () => settings.value.toGeneration(
        models.loadedParamsB,
        cloud: engine.isCloud,
      ),
      store: (snapshot, {required generating}) =>
          _persist(snapshot, generating),
      extraTools: _mcpDefinitions,
      applySettings: _applySettings,
      mcpApproval: _mcpApprovalRequired,
    )..setThinking(settings.value.thinking);
    chat.addListener(_syncForeground);
    _applyProvider();
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

  /// Shared with [updates]: a download keeps running when another app is in front.
  final ForegroundService foreground;
  late final ChatController chat;

  /// Whether the model that answers takes images, so attached pictures are read as pictures.
  /// The device model never does: it reads text only.
  bool get acceptsImages => engine.cloudProvider?.capabilities.vision ?? false;

  AppPage page = AppPage.chat;

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
  String? conversationId;
  InterruptedConversation? interrupted;
  List<ConversationMeta> conversations = const [];

  /// Text shown briefly at the bottom of the screen.
  final toast = ValueNotifier<String?>(null);
  Timer? _toastTimer;

  /// [supportDirectory] replaces the platform's app-data folder (tests use a temporary one).
  static Future<AppController> create({
    Directory? supportDirectory,
    UpdateService? updateService,
  }) async {
    final settings = await SettingsStore.load();
    final providers = await ProviderStore.load();
    final device = DeviceInfoService();
    final native = NativeEngine();
    final models = await ModelManager.create(
      engine: native,
      settings: settings,
      device: device,
      supportDirectory: supportDirectory,
    );
    final history = await ConversationDatabase.open(
      supportDirectory: supportDirectory,
    );
    final foreground = ForegroundService();
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
    );
    final local = app.engine.local;
    if (local is KvStatePersistence) {
      app._kv = KvSnapshotService(
        database: history,
        engine: local as KvStatePersistence,
        config: () => settings.value.kvSnapshot,
      );
    }
    app.engine.coding = CodingEngine(
      settings: () => settings.value.coding,
      roleFor: app._roleFor,
    );
    unawaited(app._start());
    return app;
  }

  late final _http = packageHttpGet(
    timeoutOf: () => Duration(seconds: settings.value.httpTimeoutSeconds.clamp(3, 300)),
  );

  /// Built per call so a changed SearXNG address or search switch applies immediately.
  late final ToolRuntime _toolRuntime = _SettingsToolRuntime(
    settings,
    providers,
    _http,
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
          ),
        ),
  ];

  McpTools get _mcpTools => McpTools(_mcpServerClients(), cache: _mcpCache);

  /// The tools of every MCP server, added to the ones the agent already has.
  Future<List<ToolDefinition>> _mcpDefinitions() => _mcpTools.definitions();

  /// Whether an MCP tool should wait for the user; a server can turn this off for itself.
  bool _mcpApprovalRequired(String name) => _mcpTools.approvalRequired(name);

  /// Used by the settings screen: asks one server what it offers and says so in a toast.
  Future<String> probeMcp(String id) => _mcpTools.describe(id);

  Future<void> _start() async {
    settings.addListener(() => chat.setThinking(settings.value.thinking));
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
      if (settings.value.providerTimeoutSeconds == timeout) return;
      timeout = settings.value.providerTimeoutSeconds;
      _applyProvider();
    });
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

  /// The model behind a `provider|model` reference of the coding mode, or null when it cannot be
  /// used now: the provider was removed or is incomplete, or the device model is not loaded.
  RoleModel? _roleFor(String ref) {
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
    return ProviderRole(
      providers.build(config, model: config.modelById(modelId) ?? config.defaultModel),
    );
  }

  /// Keeps Android's foreground service in step with whether a reply is being generated.
  void _syncForeground() {
    if (chat.state.isGenerating) {
      unawaited(foreground.start());
    } else {
      unawaited(foreground.stop());
    }
  }

  /// Points the router at the chosen provider; the device model when none is usable.
  void _applyProvider() {
    providers.requestTimeout = Duration(seconds: settings.value.providerTimeoutSeconds.clamp(10, 1800));
    final provider = providers.buildActive();
    if (provider != null) cloud.provider = provider;
    engine.target = provider;
    notifyListeners();
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
        ? '${models.loadedName ?? 'モデル'} · ${models.backend ?? ''}'
        : 'モデル未接続 · デモ応答のみ';
  }

  /// [ProviderList.localId] goes back to the device model.
  Future<void> setActiveProvider(String id) async {
    if (chat.state.isGenerating) {
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
    if (chat.state.isGenerating) return;
    unawaited(_saveKv(leaving: true));
    conversationId = null;
    chat.clear();
    goTo(AppPage.chat);
    notifyListeners();
  }

  Future<void> openConversation(String id) async {
    if (chat.state.isGenerating) return;
    final snapshot = await history.get(id);
    if (snapshot == null) return;
    if (id != conversationId) unawaited(_saveKv(leaving: true));
    chat.restore(snapshot);
    conversationId = id;
    goTo(AppPage.chat);
    notifyListeners();
    _restoreKv(id);
  }

  Future<void> deleteConversation(String id) async {
    // its cache is deleted with it; saving it first would be for nothing
    if (_kvOwner == id) _kvOwner = null;
    await history.delete(id);
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
    chat.restore(snapshot);
    conversationId = item.id;
    goTo(AppPage.chat);
    notifyListeners();
    _restoreKv(item.id);
    if (action == 'resume') {
      if (chat.state.canContinue) {
        unawaited(chat.continueReply());
      } else {
        unawaited(chat.regenerate());
      }
    } else {
      unawaited(chat.regenerate());
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
    if (chat.state.isGenerating) return;
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
            stillWanted: () => conversationId == id && !chat.state.isGenerating && chat.state.messages.length == seen,
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

  void _persist(ConversationSnapshot snapshot, bool generating) {
    if (snapshot.messages.isEmpty) return;
    final providerId = providers.activeId;
    final modelId = providers.activeModelId;
    _writer = _writer.then((_) async {
      try {
        final id = await history.save(
          conversationId,
          snapshot,
          generating: generating,
          providerId: providerId,
          modelId: modelId,
        );
        if (conversationId == null) {
          conversationId = id;
          notifyListeners();
        }
        // the device model has just worked on this conversation: its cache is the one to keep
        if (!generating && !providers.isCloud && models.isLoaded) _kvOwner = id;
        await refreshConversations();
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
    unawaited(foreground.stop());
    providers.removeListener(_applyProvider);
    unawaited(preview.dispose());
    updates.dispose();
    super.dispose();
  }
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
  _SettingsToolRuntime(this._settings, this._providers, this._http);

  final SettingsStore _settings;
  final ProviderStore _providers;
  final HttpGet _http;

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
              ),
            ),
      ];
      return McpTools(servers).run(call);
    }
    final s = _settings.value;
    final providers = <SearchProvider>[
      if (s.searxngUrl.trim().isNotEmpty)
        SearXngProvider(s.searxngUrl.trim(), _http),
      DuckDuckGoInstantProvider(_http),
    ];
    return DefaultToolRuntime(
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
    final b = StringBuffer('プロバイダとモデル（設定画面から追加・編集できます）:\n');
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
    b.write('APIキーとMCPトークンは、このツールでも設定画面でも読み出せません（変更もできません）。');
    return b.toString();
  }
}
