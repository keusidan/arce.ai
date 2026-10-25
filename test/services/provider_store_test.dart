import 'package:arce_ai/ai/fallback.dart';
import 'package:arce_ai/ai/model_info.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/services/provider_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderConfig orca({List<ModelInfo> catalog = const [], List<ModelConfig> models = const []}) => ProviderConfig(
      id: 'orca',
      label: 'OrcaRouter',
      baseUrl: 'https://orca.example/v1',
      models: models,
      catalog: catalog,
    );

ProviderConfig deepinfra() => const ProviderConfig(
      id: 'deepinfra',
      label: 'DeepInfra',
      baseUrl: 'https://deepinfra.example/v1',
      models: [ModelConfig(id: 'deepseek-ai/DeepSeek-V3', name: 'DeepSeek V3')],
    );

Future<ProviderStore> store() async {
  SharedPreferences.setMockInitialValues({});
  return ProviderStore.load();
}

void main() {
  test('モデルの一覧（catalog）は、保存して読み戻しても残る', () async {
    final s = await store();
    await s.save(orca(catalog: const [ModelInfo('anthropic/claude-opus-5', contextTokens: 200000)]));
    final again = await ProviderStore.load();
    expect(again.byId('orca')!.catalog.single.id, 'anthropic/claude-opus-5');
    expect(again.byId('orca')!.catalog.single.contextTokens, 200000);
  });

  test('一覧にだけあるモデルを選ぶと、上限つきで設定に加わり、使用中になる', () async {
    final s = await store();
    await s.save(orca(catalog: const [ModelInfo('anthropic/claude-opus-5', contextTokens: 200000, maxOutputTokens: 32000)]));
    expect(s.byId('orca')!.models, isEmpty);

    expect(await s.selectModel('orca', 'anthropic/claude-opus-5'), isTrue);
    final model = s.byId('orca')!.modelById('anthropic/claude-opus-5')!;
    expect(model.contextTokens, 200000);
    expect(model.maxOutputTokens, 32000);
    expect(s.activeId, 'orca');
    expect(s.activeModelId, 'anthropic/claude-opus-5');
  });

  test('一覧にも設定にも無いモデルは選べない', () async {
    final s = await store();
    await s.save(orca());
    expect(await s.selectModel('orca', 'nothing'), isFalse);
    expect(await s.selectModel('missing', 'x'), isFalse);
    expect(s.activeId, ProviderList.localId);
  });

  test('一覧を読み直すと、設定済みのモデルの空欄の上限だけが埋まる（入れた値は変えない）', () async {
    final s = await store();
    await s.save(orca(models: const [
      ModelConfig(id: 'a', name: 'a'),
      ModelConfig(id: 'b', name: 'b', contextTokens: 1000),
    ]));
    final added = await s.updateCatalog('orca', const [
      ModelInfo('a', contextTokens: 128000),
      ModelInfo('b', contextTokens: 999999),
      ModelInfo('c'),
    ]);
    expect(added, 3);
    final config = s.byId('orca')!;
    expect(config.modelById('a')!.contextTokens, 128000);
    expect(config.modelById('b')!.contextTokens, 1000);
    expect(config.models.length, 2, reason: '新しいモデルを、設定の一覧に勝手に足さない');
    expect(config.catalog.length, 3);
    expect(config.catalogAt, isNotNull);
    expect(await s.updateCatalog('orca', const [ModelInfo('a'), ModelInfo('c')]), 0);
    expect(await s.updateCatalog('missing', const []), isNull);
  });

  test('knownIds は、設定したモデルが先、一覧のモデルが続く。重ならない', () {
    final config = orca(
      models: const [ModelConfig(id: 'b', name: 'b')],
      catalog: const [ModelInfo('a'), ModelInfo('b'), ModelInfo('c')],
    );
    expect(config.knownIds, ['b', 'a', 'c']);
    expect(config.resolveModel('c')!.id, 'c');
    expect(config.resolveModel('zzz'), isNull);
  });

  test('最近使ったモデルは、新しい順。同じものは前に出し、数を超えた古いものは落とし、保存する', () async {
    final s = await store();
    await s.markUsed('orca', 'a', keep: 3);
    await s.markUsed('orca', 'b', keep: 3);
    await s.markUsed('deepinfra', 'c', keep: 3);
    await s.markUsed('orca', 'a', keep: 3);
    expect(s.recentRefs, ['orca|a', 'deepinfra|c', 'orca|b']);
    await s.markUsed('orca', 'd', keep: 3);
    expect(s.recentRefs, ['orca|d', 'orca|a', 'deepinfra|c']);
    expect((await ProviderStore.load()).recentRefs, ['orca|d', 'orca|a', 'deepinfra|c']);
  });

  test('同じモデルで答え続けても、画面への通知は増えない', () async {
    final s = await store();
    await s.markUsed('orca', 'a');
    var notified = 0;
    s.addListener(() => notified++);
    await s.markUsed('orca', 'a');
    await s.markUsed('orca', 'a');
    expect(notified, 0);
    await s.markUsed('orca', 'b');
    expect(notified, 1);
  });

  group('フォールバック', () {
    test('ルールは保存して読み戻せる', () async {
      final s = await store();
      await s.setFallbackRules(const [FallbackRule(from: 'orca|*', targets: ['deepinfra|deepseek-ai/DeepSeek-V3'])]);
      final again = await ProviderStore.load();
      expect(again.fallbackRules.single.from, 'orca|*');
    });

    test('使うモデルのルールから、次のモデルを組み立てる。自分自身・使えない提供元・知らないモデルは飛ばす', () async {
      final s = await store();
      await s.save(orca(models: const [ModelConfig(id: 'free', name: 'free')]));
      await s.save(deepinfra());
      await s.setFallbackRules(const [
        FallbackRule(from: 'orca|free', targets: [
          'orca|free',
          'missing|x',
          'deepinfra|unknown-model',
          'deepinfra|deepseek-ai/DeepSeek-V3',
          'deepinfra|',
        ]),
      ]);
      final primary = s.build(s.byId('orca')!, model: s.byId('orca')!.modelById('free'));
      final plan = s.fallbackPlanFor(primary)!;
      expect([for (final t in plan.targets) '${t.id}|${t.modelId}'], [
        'deepinfra|deepseek-ai/DeepSeek-V3',
        'deepinfra|deepseek-ai/DeepSeek-V3', // the empty model means the provider's own first one
      ]);
      expect(plan.statuses, FallbackPolicy.defaultStatuses);
    });

    test('ルールが無い、または使える代わりが無いなら、null', () async {
      final s = await store();
      await s.save(orca(models: const [ModelConfig(id: 'free', name: 'free')]));
      final primary = s.build(s.byId('orca')!, model: s.byId('orca')!.modelById('free'));
      expect(s.fallbackPlanFor(primary), isNull);
      await s.setFallbackRules(const [FallbackRule(from: '*', targets: ['gone|x'])]);
      expect(s.fallbackPlanFor(primary), isNull);
    });

    test('ルールに書いた番号は、そのまま使われる', () async {
      final s = await store();
      await s.save(orca(models: const [ModelConfig(id: 'free', name: 'free')]));
      await s.save(deepinfra());
      await s.setFallbackRules(const [FallbackRule(from: '*', targets: ['deepinfra|'], statuses: {429})]);
      final primary = s.build(s.byId('orca')!, model: s.byId('orca')!.modelById('free'));
      expect(s.fallbackPlanFor(primary)!.statuses, {429});
    });
  });
}
