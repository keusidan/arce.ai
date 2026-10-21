import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ai/cloud_engine.dart';
import '../ai/provider.dart';
import '../ai/routing_engine.dart';
import '../core/chat_controller.dart';
import '../core/http_get.dart';
import '../core/search.dart';
import '../core/settings_spec.dart';
import '../core/tool_runtime.dart';
import '../core/weather.dart';
import '../engine/demo_engine.dart';
import '../engine/hybrid_engine.dart';
import '../engine/native_engine.dart';
import 'conversation_database.dart';
import 'device_info.dart';
import 'model_manager.dart';
import 'preview_server.dart';
import 'provider_store.dart';
import 'settings.dart';
import 'update_service.dart';

enum AppPage { chat, models, artifacts, settings, history }

/// Anchors of the sections of the settings page, so the desktop sidebar can jump to one.
enum SettingsSection { providers, basic, answer, display, developer, update }

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
    required this.device,
    required this.cloud,
    required this.engine,
    required this.preview,
  }) {
    chat = ChatController(
      engine,
      toolRuntime: _toolRuntime,
      settings: () => settings.value.toGeneration(models.loadedParamsB),
      store: (snapshot, {required generating}) => _persist(snapshot, generating),
      applySettings: _applySettings,
    )..setThinking(settings.value.thinking);
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
  late final ChatController chat;

  AppPage page = AppPage.chat;

  /// Which part of the settings page to scroll to (set by the desktop sidebar).
  final settingsSection = ValueNotifier<SettingsSection?>(null);
  String? conversationId;
  InterruptedConversation? interrupted;
  List<ConversationMeta> conversations = const [];

  /// Text shown briefly at the bottom of the screen.
  final toast = ValueNotifier<String?>(null);
  Timer? _toastTimer;

  /// [supportDirectory] replaces the platform's app-data folder (tests use a temporary one).
  static Future<AppController> create({Directory? supportDirectory, UpdateService? updateService}) async {
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
    final history = await ConversationDatabase.open(supportDirectory: supportDirectory);
    final updates = updateService ?? UpdateService(settings);
    final cloud = CloudEngine(const _NoProvider());
    final app = AppController._(
      settings: settings,
      providers: providers,
      history: history,
      models: models,
      updates: updates,
      device: device,
      cloud: cloud,
      // the device model answers until the user picks a provider
      engine: RoutingEngine(local: HybridEngine(native, DemoEngine()), cloud: cloud),
      preview: PreviewServer(),
    );
    unawaited(app._start());
    return app;
  }

  final _http = packageHttpGet();

  /// Built per call so a changed SearXNG address or search switch applies immediately.
  late final ToolRuntime _toolRuntime = _SettingsToolRuntime(settings, _http);

  /// Applies the settings the user approved in the chat (protocol `update_settings`). The reply
  /// says what the settings are now, so the model can confirm instead of assuming.
  Future<String> _applySettings(List<SettingsChangeOk> changes) async {
    await settings.update((current) => withSettings(current, changes));
    final values = settings.value.toJson();
    final now = [
      for (final change in changes) '${change.key}=${change.spec.format(values[change.key])}',
    ].join(', ');
    final reload = changes.any((c) => _reloadNeeded.contains(c.key));
    return 'The user approved the change: $now.'
        '${reload ? ' It takes effect the next time the model is loaded.' : ''}';
  }

  /// Settings a running model keeps until it is loaded again.
  static const _reloadNeeded = {'contextLength', 'threads', 'batchSize', 'gpuOffload'};

  Future<void> _start() async {
    settings.addListener(() => chat.setThinking(settings.value.thinking));
    // adding, removing or editing a provider changes which one answers
    providers.addListener(_applyProvider);
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
    unawaited(updates.init().catchError((Object e) => debugPrint('update check setup failed: $e')));
    unawaited(models.restoreLastModel().catchError((Object e) => debugPrint('could not restore the last model: $e')));
  }

  /// Points the router at the chosen provider; the device model when none is usable.
  void _applyProvider() {
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
    if (config != null) return '${config.label} · ${config.model}（外部送信）';
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
    _toastTimer = Timer(const Duration(milliseconds: 2200), () => toast.value = null);
  }

  Future<void> refreshConversations() async {
    conversations = await history.list();
    notifyListeners();
  }

  void newConversation() {
    if (chat.state.isGenerating) return;
    conversationId = null;
    chat.clear();
    goTo(AppPage.chat);
    notifyListeners();
  }

  Future<void> openConversation(String id) async {
    if (chat.state.isGenerating) return;
    final snapshot = await history.get(id);
    if (snapshot == null) return;
    chat.restore(snapshot);
    conversationId = id;
    goTo(AppPage.chat);
    notifyListeners();
  }

  Future<void> deleteConversation(String id) async {
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
    chat.restore(snapshot);
    conversationId = item.id;
    goTo(AppPage.chat);
    notifyListeners();
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
        .map((m) => '${m.role == Role.user ? '## User' : '## ARCE.AI'}\n${m.text}')
        .join('\n\n');
  }

  // One writer at a time, in order: the first save of a new chat must get its id before the next.
  Future<void> _writer = Future.value();

  void _persist(ConversationSnapshot snapshot, bool generating) {
    if (snapshot.messages.isEmpty) return;
    final providerId = providers.activeId;
    final modelId = providers.active?.model ?? '';
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
        await refreshConversations();
      } catch (e) {
        debugPrint('could not save the conversation: $e');
      }
    });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
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
  ProviderCapabilities get capabilities => const ProviderCapabilities();

  @override
  Stream<Delta> stream(AiRequest request) async* {
    throw const AiProviderException('プロバイダが設定されていません');
  }

  @override
  Future<void> verify() async => throw const AiProviderException('プロバイダが設定されていません');
}

/// Tools read the settings at call time, so a changed SearXNG address or search switch applies at once.
class _SettingsToolRuntime implements ToolRuntime {
  _SettingsToolRuntime(this._settings, this._http);

  final SettingsStore _settings;
  final HttpGet _http;

  @override
  Future<ToolOutcome> run(call) {
    final s = _settings.value;
    final providers = <SearchProvider>[
      if (s.searxngUrl.trim().isNotEmpty) SearXngProvider(s.searxngUrl.trim(), _http),
      DuckDuckGoInstantProvider(_http),
    ];
    return DefaultToolRuntime(
      search: s.searchEnabled ? SearchService(providers, retriesPerProvider: s.retryLimit.clamp(0, 3)) : null,
      weather: OpenMeteoWeather(_http),
      settingsValues: () => _settings.value.toJson(),
    ).run(call);
  }
}
