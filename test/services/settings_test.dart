import 'package:arce_ai/core/engine.dart';
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
