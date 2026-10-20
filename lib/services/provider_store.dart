import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/openai_compatible.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';

/// The providers the user added, which one is in use, and their keys.
///
/// The list and the choice are one JSON document in shared preferences. The keys are kept apart
/// in the platform's secure storage (`provider_key.<id>`), so nothing secret ends up in a file
/// that can be copied, backed up or exported.
class ProviderStore extends ChangeNotifier {
  ProviderStore(this._prefs, {FlutterSecureStorage? secure})
      : _secure = secure ??
            // the legacy keychain needs no entitlement or provisioning profile, so unsigned builds can use it
            const FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  static const _listKey = 'providers.v1';
  static const _activeKey = 'providers.active';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  List<ProviderConfig> _providers = const [];
  final Map<String, String> _keys = {};
  String _active = ProviderList.localId;

  List<ProviderConfig> get providers => List.unmodifiable(_providers);

  /// `local` for the device model, otherwise the id of a provider the user added.
  String get activeId => _active;

  /// True when replies go to a cloud provider rather than the model on the device.
  bool get isCloud => _active != ProviderList.localId;

  /// The provider in use, or null for the device model.
  ProviderConfig? get active => byId(_active);

  ProviderConfig? byId(String id) {
    for (final provider in _providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  /// The key of [id]; empty when none is set, or when secure storage is unavailable here.
  String keyOf(String id) => _keys[id] ?? '';

  bool hasKey(String id) => keyOf(id).trim().isNotEmpty;

  static Future<ProviderStore> load({FlutterSecureStorage? secure}) async {
    final store = ProviderStore(await SharedPreferences.getInstance(), secure: secure);
    store._providers = ProviderList.decode(store._prefs.getString(_listKey));
    final saved = store._prefs.getString(_activeKey);
    // a provider that was removed must not stay selected
    store._active = store.byId(saved ?? '') != null ? saved! : ProviderList.localId;
    for (final provider in store._providers) {
      try {
        store._keys[provider.id] = await store._secure.read(key: provider.keyRef) ?? '';
      } catch (_) {
        store._keys[provider.id] = '';
      }
    }
    return store;
  }

  /// Adds [config] or replaces the provider with the same id.
  Future<void> save(ProviderConfig config) async {
    _providers = [
      for (final provider in _providers)
        if (provider.id != config.id) provider,
      config,
    ];
    notifyListeners();
    await _persistList();
  }

  Future<void> remove(String id) async {
    _providers = [for (final provider in _providers) if (provider.id != id) provider];
    _keys.remove(id);
    if (_active == id) _active = ProviderList.localId;
    notifyListeners();
    await _persistList();
    await _persistActive();
    try {
      await _secure.delete(key: ProviderConfig(id: id, label: '', baseUrl: '', model: '').keyRef);
    } catch (_) {
      // without a keyring the key was only in memory
    }
  }

  /// Selects [id], or the device model when it is [ProviderList.localId].
  Future<void> setActive(String id) async {
    _active = id == ProviderList.localId || byId(id) == null ? ProviderList.localId : id;
    notifyListeners();
    await _persistActive();
  }

  Future<void> setKey(String id, String key) async {
    _keys[id] = key.trim();
    notifyListeners();
    try {
      final ref = ProviderConfig(id: id, label: '', baseUrl: '', model: '').keyRef;
      if (key.trim().isEmpty) {
        await _secure.delete(key: ref);
      } else {
        await _secure.write(key: ref, value: key.trim());
      }
    } catch (_) {
      // keep the key for this run only when the system keyring is missing
    }
  }

  /// The provider in use, ready to send requests; null for the device model, or when the stored
  /// settings are not usable yet (the screen then shows what is missing instead of sending).
  AiProvider? buildActive({http.Client? client}) {
    final config = active;
    if (config == null || !config.isComplete) return null;
    return build(config, client: client);
  }

  /// A provider built from [config] and its saved key; used by the connection check as well.
  AiProvider build(ProviderConfig config, {http.Client? client}) => OpenAiCompatibleProvider(
        id: config.id,
        label: config.label,
        baseUrl: config.baseUrl,
        model: config.model,
        apiKey: keyOf(config.id),
        headers: config.headers,
        body: config.body,
        supportsTools: config.supportsTools,
        client: client,
      );

  Future<void> _persistList() => _prefs.setString(_listKey, ProviderList.encode(_providers));

  Future<void> _persistActive() => _prefs.setString(_activeKey, _active);
}
