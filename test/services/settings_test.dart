import 'dart:convert';

import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/settings_spec.dart';
import 'package:arce_ai/core/search.dart';
import 'package:arce_ai/mcp/mcp_server.dart';
import 'package:arce_ai/services/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('settings survive a JSON round trip and unknown values fall back', () {
    const original = AppSettings(
      thinking: false,
      theme: ThemeMode.dark,
      thinkingStyle: ThinkingStyle.rotation,
      kvCache: KvCacheType.q8_0,
      gpuOffload: GpuOffload.maxGpu,
      contextLength: 8192,
      updateRepo: 'someone/else',
    );
    final back = AppSettings.fromJson(original.toJson());
    expect(back.toJson(), original.toJson());

    final damaged = AppSettings.fromJson({
      'theme': 'neon',
      'contextLength': 'lots',
      'thinking': 3,
    });
    expect(damaged.theme, ThemeMode.system);
    expect(damaged.contextLength, 4096);
    expect(damaged.thinking, isTrue);
  });

  test('the 0.9.0 model settings: defaults, round trip, and the chat may change them', () {
    const d = AppSettings();
    expect(d.thinkingExpanded, isTrue, reason: 'the thinking is shown open unless the user folds it');
    expect(d.tokenPrecheck, isTrue);
    expect(d.fallbackEnabled, isTrue);
    expect(d.maxToolRounds, 30);

    const custom = AppSettings(thinkingExpanded: false, tokenPrecheck: false, fallbackEnabled: false, tokenOverheadPercent: 60, recentModelCount: 3);
    final back = AppSettings.fromJson(custom.toJson());
    expect(back.thinkingExpanded, isFalse);
    expect(back.tokenPrecheck, isFalse);
    expect(back.fallbackEnabled, isFalse);
    expect(back.tokenOverheadPercent, 60);
    expect(back.recentModelCount, 3);
    expect(back.toJson(), custom.toJson());

    expect(d.mcpResultMaxChars, 30000);
    expect(AppSettings.fromJson(const AppSettings(mcpResultMaxChars: 9000).toJson()).mcpResultMaxChars, 9000);
    expect(AppSettings.fromJson({'mcpResultMaxChars': 3}).mcpResultMaxChars, 500, reason: 'kept inside its range');
    expect(AgentSettings.isEditable('mcpResultMaxChars'), isTrue);
    expect(AgentSettings.isEditable('thinkingExpanded'), isTrue);
    expect(AgentSettings.normalize('thinkingExpanded', false), isA<SettingsChangeOk>());
  });

  test('the device model and the online models have their own settings', () {
    const s = AppSettings(
      maxTokens: 2048,
      localTemperature: 0.3,
      localTopK: 40,
      localMaxTokens: 512,
      localPrompt: ' 簡潔に ',
      onlineTemperature: 1.2,
      onlineTopP: 0.5,
      onlineMaxTokens: 4096,
    );
    final back = AppSettings.fromJson(s.toJson());
    expect(back.localTemperature, 0.3);
    expect(back.onlineTemperature, 1.2);

    final local = s.toGeneration(null);
    expect(local.temperature, 0.3);
    expect(local.topK, 40);
    expect(local.maxTokens, 512);
    expect(local.extraPrompt, '簡潔に');
    expect(local.topP, isNull, reason: 'not set: the app value applies');

    final online = s.toGeneration(null, cloud: true);
    expect(online.temperature, 1.2);
    expect(online.topP, 0.5);
    expect(online.maxTokens, 4096);
    expect(online.topK, isNull, reason: 'top_k is for the device engine only');
    expect(online.extraPrompt, isEmpty, reason: 'the local prompt never reaches an online model');

    // nothing set: every value is the app's own
    final plain = const AppSettings().toGeneration(null);
    expect(plain.temperature, isNull);
    expect(plain.maxTokens, 2048);
    const base = SamplingParams.qwen3Thinking;
    expect(plain.applyTo(base).temperature, base.temperature);
    expect(local.applyTo(base).temperature, 0.3);
    expect(local.applyTo(base).topP, base.topP);
  });

  test('the coding mode settings round-trip, and are kept inside their limits', () {
    const s = AppSettings(
      codingPlanEnabled: true,
      plannerModel: 'openai|gpt-4o',
      developerModel: 'local|',
      codingMaxTasks: 99,
      codingParallel: 0,
      codingReviewRounds: -3,
      codingDeveloperMaxTokens: 8192,
    );
    final back = AppSettings.fromJson(s.toJson());
    expect(back.coding.enabled, isTrue);
    expect(back.coding.planner, 'openai|gpt-4o');
    expect(back.coding.developer, 'local|');
    expect(back.coding.maxTasks, 8, reason: 'too many tasks is cut to the limit');
    expect(back.coding.parallel, 1);
    expect(back.coding.reviewRounds, 0);
    expect(back.coding.developerMaxTokens, 8192);
    expect(const AppSettings().coding.isReady, isFalse, reason: 'off until the user turns it on');
  });

  test('limits and timeouts are settings, kept inside sane ranges', () {
    final s = const AppSettings(
      attachMaxFiles: 99,
      attachCharsPerFile: 10,
      attachTotalChars: 20000,
      attachImageMb: 8,
      toolRepeatLimit: 1,
      localDryMultiplier: 1.5,
    );
    final back = AppSettings.fromJson(s.toJson());
    expect(back.attachmentLimits.maxFiles, 20, reason: 'cut to the limit');
    expect(back.attachmentLimits.maxCharsPerFile, 500);
    expect(back.attachmentLimits.maxTotalChars, 20000);
    expect(back.attachmentLimits.maxImageBytes, 8 * 1024 * 1024);

    final generation = back.toGeneration(null);
    expect(generation.toolRepeatLimit, 2, reason: 'one identical call is not a loop');
    expect(generation.attachments.maxFiles, 20);
    expect(generation.dryMultiplier, 1.5);
    expect(back.toGeneration(null, cloud: true).dryMultiplier, isNull, reason: 'DRY is the device model\'s');

    // nothing changed: the values the app always had
    const d = AppSettings();
    expect(d.attachmentLimits.maxFiles, 5);
    expect(d.attachmentLimits.maxCharsPerFile, 8000);
    expect(d.attachmentLimits.maxTotalChars, 16000);
    expect(d.searchResultCount, 5);
    expect(d.httpTimeoutSeconds, 20);
    expect(d.mcpTimeoutSeconds, 40);
    expect(d.providerTimeoutSeconds, 120);
    expect(d.toolRepeatLimit, 3);
    expect(d.updateRetryAttempts, 5);
    expect(d.updateStallSeconds, 30);
  });

  test('KV cache saving is off by default, and its limits stay in range', () {
    const d = AppSettings();
    expect(d.kvSnapshotEnabled, isFalse, reason: 'it costs disk space, so the user turns it on');
    expect(d.kvSnapshot.enabled, isFalse);
    expect(d.kvSnapshot.maxBytes, 1024 * 1024 * 1024);
    expect(d.kvSnapshot.minTokens, 512);

    final s = AppSettings.fromJson(const AppSettings(kvSnapshotEnabled: true, kvSnapshotMaxMb: 5, kvSnapshotMinTokens: 1).toJson());
    expect(s.kvSnapshot.enabled, isTrue);
    expect(s.kvSnapshot.maxBytes, 64 * 1024 * 1024, reason: 'too small a limit is raised to the smallest one');
    expect(s.kvSnapshot.minTokens, 64);
    expect(AppSettings.fromJson({'kvCache': 'q4_0'}).kvCache, KvCacheType.q4_0);
  });

  test('the developer token budget is automatic (0) unless the user picked one; 0.8.1 defaults migrate', () {
    expect(const AppSettings().coding.developerMaxTokens, 0);
    // 0.8.1 wrote its fixed default (4096) into every saved settings document
    final old = AppSettings.fromJson({'codingDeveloperMaxTokens': 4096});
    expect(old.coding.developerMaxTokens, 0);
    final chosen = AppSettings.fromJson({'codingDeveloperMaxTokens': 262144});
    expect(chosen.coding.developerMaxTokens, 262144, reason: 'a 256K budget is allowed now');
    expect(AppSettings.fromJson(chosen.toJson()).coding.developerMaxTokens, 262144);
  });

  test('the planner works with its own limit set in the chat: the result length is a setting; the old planner budget is gone', () {
    expect(const AppSettings().coding.resultChars, 12000);
    expect(AppSettings.fromJson(const AppSettings(codingResultChars: 6000).toJson()).coding.resultChars, 6000);
    expect(AppSettings.fromJson({'codingResultChars': 5}).coding.resultChars, 500, reason: 'kept inside its range');
    expect(AppSettings.fromJson({'codingPlannerMaxTokens': 16384}).toJson().containsKey('codingPlannerMaxTokens'), isFalse, reason: 'an old save is read, and the key is dropped');
    expect(AgentSettings.isEditable('codingResultChars'), isTrue);
  });

  test('model info lookup is on by default, and the user-set reply length is passed on', () {
    const d = AppSettings();
    expect(d.autoFetchModelInfo, isTrue);
    expect(d.fetchModelInfoFromHub, isTrue);
    expect(AppSettings.fromJson(const AppSettings(autoFetchModelInfo: false).toJson()).autoFetchModelInfo, isFalse);

    expect(d.toGeneration(null, cloud: true).userMaxTokens, isNull, reason: 'nothing set: the maker\'s recommendation may apply');
    expect(const AppSettings(onlineMaxTokens: 9000).toGeneration(null, cloud: true).userMaxTokens, 9000);
    expect(const AppSettings(localMaxTokens: 500).toGeneration(null).userMaxTokens, 500);
    expect(const AppSettings(onlineMaxTokens: 9000).toGeneration(null).userMaxTokens, isNull, reason: 'the online setting never reaches the device model');
  });

  test('threads and GPU layers follow HyperLoad and the offload setting', () {
    expect(const AppSettings().effectiveThreads(8), 4);
    expect(const AppSettings(hyperLoad: true).effectiveThreads(8), 8);
    expect(const AppSettings(threads: 3).effectiveThreads(8), 3);
    expect(const AppSettings().gpuLayers(gpuAvailable: true), 20);
    expect(
      const AppSettings(hyperLoad: true).gpuLayers(gpuAvailable: true),
      999,
    );
    expect(
      const AppSettings(gpuOffload: GpuOffload.cpuOnly)
          .gpuLayers(gpuAvailable: true),
      0,
    );
    expect(
      const AppSettings(gpuOffload: GpuOffload.gpuPriority)
          .gpuLayers(gpuAvailable: false),
      0,
    );
  });

  test('the store saves changes and loads them next time', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.load();
    await store.update(
      (s) => s.copyWith(searxngUrl: 'http://pi:8080', maxChars: 800),
    );

    final again = await SettingsStore.load();
    expect(again.value.searxngUrl, 'http://pi:8080');
    expect(again.value.maxChars, 800);
  });

  test('search services are saved, their keys are not', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.load();
    final api = SearchApiConfig.presets['Brave Search']!.copyWith(name: 'Brave Search');
    final saved = SearchApiConfig.fromJson({...api.toJson(), 'id': 'brave-search'});
    await store.update((s) => s.copyWith(searchApis: [saved]));
    await store.setSearchKey('brave-search', '  BSA-secret  ');

    expect(store.searchKeyOf('brave-search'), 'BSA-secret');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings.v1'), isNot(contains('BSA-secret')));
    expect(jsonEncode(store.value.toJson()), isNot(contains('BSA-secret')));

    final again = await SettingsStore.load();
    expect(again.value.searchApis.single.url, saved.url);

    await store.forgetSearchKey('brave-search');
    expect(store.searchKeyOf('brave-search'), isEmpty);
  });

  test('a damaged save does not stop the app from starting', () async {
    SharedPreferences.setMockInitialValues({'settings.v1': '{not json'});
    final store = await SettingsStore.load();
    expect(store.value.thinking, isTrue);
  });

  test('a single MCP endpoint from an older save becomes one server', () {
    final back = AppSettings.fromJson({
      'mcpEnabled': true,
      'mcpUrl': 'https://mcp.example/v1',
    });
    expect(back.mcpServers, hasLength(1));
    expect(back.mcpServers.single.url, 'https://mcp.example/v1');
    expect(back.mcpServers.single.enabled, isTrue);
    expect(back.mcpServers.single.id, 'default');
  });

  test('several MCP servers and their settings survive a round trip', () {
    const original = AppSettings(
      mcpServers: [
        McpServerConfig(
          id: 'github',
          name: 'GitHub',
          url: 'https://api.githubcopilot.com/mcp/',
        ),
        McpServerConfig(
          id: 'home',
          name: '自宅',
          url: 'http://pi:9000/mcp',
          enabled: false,
          approveWrites: false,
        ),
      ],
    );
    final back = AppSettings.fromJson(original.toJson());
    expect(back.mcpServers.map((s) => s.id), ['github', 'home']);
    expect(back.mcpServers.last.enabled, isFalse);
    expect(back.mcpServers.last.approveWrites, isFalse);
  });
}
