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
