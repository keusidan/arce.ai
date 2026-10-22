import 'dart:convert';

import 'package:flutter/material.dart';

import '../ai/model_hints.dart';
import '../ai/model_info.dart';
import '../ai/openai_compatible.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';
import '../services/app_controller.dart';
import '../services/provider_store.dart';
import 'app_scope.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// The providers, in one list with the device model: either can be the one in use.
///
/// Picking a row switches the engine for the next reply; the choice is stored, so it survives a
/// restart. The key of a provider is kept in the platform's secure storage, not in the settings
/// file, and is only sent to that provider.
class ProvidersSection extends StatelessWidget {
  const ProvidersSection({super.key});

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return ListenableBuilder(
      listenable: app.providers,
      builder: (context, _) {
        final store = app.providers;
        final local = !store.isCloud;
        final providers = store.providers;
        return ArceCard(
          child: Column(
            children: [
              _ProviderRow(
                icon: ArceSvg.cube,
                title: '端末のモデル',
                detail: 'この端末の中だけで動きます（外部に送りません）',
                selected: local,
                badge: local ? '使用中' : null,
                onPick: () => app.setActiveProvider(ProviderList.localId),
                last: providers.isEmpty,
              ),
              for (var i = 0; i < providers.length; i++)
                _ProviderRow(
                  icon: ArceSvg.globe,
                  title: providers[i].label.isEmpty
                      ? providers[i].id
                      : providers[i].label,
                  detail:
                      '${_modelLabel(store.modelOf(providers[i].id))} · ${providers[i].baseUrl}',
                  selected: store.activeId == providers[i].id,
                  badge: providers[i].models.isEmpty
                      ? 'モデル未追加'
                      : (!store.hasKey(providers[i].id)
                            ? 'APIキー未設定'
                            : (store.activeId == providers[i].id
                                  ? '使用中'
                                  : null)),
                  onPick: () => app.setActiveProvider(providers[i].id),
                  onModels: () => _openModels(context, app, providers[i]),
                  onEdit: () => _openEditor(context, app, providers[i]),
                  onDelete: () => _confirmDelete(context, app, providers[i]),
                  last: i == providers.length - 1,
                ),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    SoftButton(
                      label: 'プロバイダを追加',
                      svg: ArceSvg.plus,
                      onTap: () => _openEditor(context, app, null),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'OpenAI 互換の API ならどれでも使えます（OpenAI、Groq、OpenRouter、Ollama、LM Studio など）。'
                  'Base URL は /chat/completions より前までです。',
                  style: ts(context, 9, color: context.c.muted, height: 1.5),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static Future<void> _confirmDelete(
    BuildContext context,
    AppController app,
    ProviderConfig config,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(config.label.isEmpty ? config.id : config.label),
        content: const Text('このプロバイダと、保存したAPIキーを削除します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('やめる'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await app.providers.remove(config.id);
    await app.setActiveProvider(app.providers.activeId);
    app.showToast('削除しました');
  }

  static String _modelLabel(ModelConfig? model) =>
      model == null ? 'モデル未追加' : model.id;

  static Future<void> _openModels(
    BuildContext context,
    AppController app,
    ProviderConfig config,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => _ModelsSheet(app: app, config: config),
    );
  }

  static Future<void> _openEditor(
    BuildContext context,
    AppController app,
    ProviderConfig? existing,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) =>
          _ProviderEditor(app: app, store: app.providers, existing: existing),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.selected,
    required this.onPick,
    this.badge,
    this.onModels,
    this.onEdit,
    this.onDelete,
    this.last = false,
  });

  final String icon;
  final String title;
  final String detail;
  final bool selected;
  final VoidCallback onPick;
  final String? badge;
  final VoidCallback? onModels;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 1),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          ArceIcon(icon, size: 16, color: selected ? c.accent : c.muted),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onPick,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          overflow: TextOverflow.ellipsis,
                          style: ts(
                            context,
                            12,
                            weight: FontWeight.w700,
                            color: selected ? c.accent : c.ink,
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 6),
                        StatusLabel(
                          badge!,
                          color: selected ? c.accent : c.amber,
                          background: selected ? c.accentSoft : c.amberSoft,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts(context, 9, color: c.muted),
                  ),
                ],
              ),
            ),
          ),
          if (onModels != null) ...[
            const SizedBox(width: 6),
            SoftButton(label: 'モデル', height: 28, onTap: onModels),
          ],
          if (onEdit != null) ...[
            const SizedBox(width: 6),
            IconTap(
              svg: ArceSvg.pencil,
              onTap: onEdit!,
              tooltip: '編集',
              size: 16,
            ),
          ],
          if (onDelete != null) ...[
            const SizedBox(width: 6),
            SoftButton(label: '削除', height: 28, onTap: onDelete),
          ],
          if (onEdit == null) ...[
            const SizedBox(width: 8),
            StatusLabel(
              selected ? '選択中' : '選ぶ',
              color: selected ? c.accent : c.muted,
            ),
          ],
        ],
      ),
    );
  }
}

/// Add or edit one provider; the connection check uses what is typed, not what was saved.
class _ProviderEditor extends StatefulWidget {
  const _ProviderEditor({
    required this.app,
    required this.store,
    this.existing,
  });

  final AppController app;
  final ProviderStore store;
  final ProviderConfig? existing;

  @override
  State<_ProviderEditor> createState() => _ProviderEditorState();
}

class _ProviderEditorState extends State<_ProviderEditor> {
  late final TextEditingController _label = TextEditingController(
    text: widget.existing?.label ?? '',
  );
  late final TextEditingController _baseUrl = TextEditingController(
    text: widget.existing?.baseUrl ?? '',
  );
  late final TextEditingController _key = TextEditingController(
    text: widget.existing == null
        ? ''
        : widget.store.keyOf(widget.existing!.id),
  );

  late final TextEditingController _headers = TextEditingController(
    text: ProviderExtras.show({...?widget.existing?.headers}),
  );
  late final TextEditingController _body = TextEditingController(
    text: ProviderExtras.show(widget.existing?.body ?? const {}),
  );
  late bool _tools = widget.existing?.supportsTools ?? true;

  String? _result;
  bool _busy = false;

  @override
  void dispose() {
    for (final controller in [_label, _baseUrl, _key, _headers, _body]) {
      controller.dispose();
    }
    super.dispose();
  }

  ProviderConfig _config() {
    final existing = widget.existing;
    final label = _label.text.trim();
    return ProviderConfig(
      id: existing?.id ?? ProviderList.idFor(label, widget.store.providers),
      label: label.isEmpty ? 'プロバイダ' : label,
      baseUrl: _baseUrl.text.trim(),
      models: existing?.models ?? const [],
      // a [FormatException] from the two JSON fields is shown by the caller
      headers: ProviderExtras.parseHeaders(_headers.text),
      body: ProviderExtras.parseBody(_body.text),
      supportsTools: _tools,
    );
  }

  /// The config the fields describe, or null (with the reason shown) when a JSON field is wrong.
  ProviderConfig? _configOrExplain() {
    try {
      return _config();
    } on FormatException catch (e) {
      setState(() => _result = e.message);
      return null;
    }
  }

  Future<void> _check() async {
    final config = _configOrExplain();
    if (config == null) return;
    final model = config.defaultModel;
    if (config.baseUrl.trim().isEmpty || model == null) {
      setState(() => _result = 'Base URL（https://…）とモデルを用意してください');
      return;
    }
    setState(() {
      _busy = true;
      _result = '接続を確認しています…';
    });
    final provider = OpenAiCompatibleProvider(
      id: config.id,
      label: config.label,
      baseUrl: config.baseUrl,
      model: model.id,
      modelConfig: model,
      apiKey: _key.text.trim(),
      headers: config.headers,
      body: config.body,
      supportsTools: config.supportsTools,
    );
    try {
      await provider.verify();
      if (!mounted) return;
      setState(() => _result = '接続できました（${model.id}）');
    } on AiProviderException catch (e) {
      if (!mounted) return;
      setState(() => _result = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _result = '接続できませんでした（$e）');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final config = _configOrExplain();
    if (config == null) return;
    if (config.baseUrl.trim().isEmpty) {
      setState(() => _result = 'Base URL（https://…）を入れてください');
      return;
    }
    await widget.store.save(config);
    await widget.store.setKey(config.id, _key.text);
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.app.showToast('${config.label} を保存しました');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final editing = widget.existing != null;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              editing ? 'プロバイダを編集' : 'プロバイダを追加',
              style: ts(context, 14, weight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            _field('名前', _label, '例: OpenAI / Groq / 自宅の Ollama'),
            _field('Base URL', _baseUrl, 'https://api.openai.com/v1'),
            _field('APIキー', _key, 'sk-…（端末の安全な領域に保存します）', obscure: true),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _tools,
              onChanged: (value) => setState(() => _tools = value),
              title: Text('ツール呼び出しに対応', style: ts(context, 12)),
              subtitle: Text(
                '検索や設定の変更などを、モデルが自分で呼べるようにします。対応しないモデルではオフに',
                style: ts(context, 9.5, color: c.muted),
              ),
            ),
            _field('追加ヘッダー（JSON・任意）', _headers, '{"HTTP-Referer": "https://example.com"}', maxLines: 3),
            _field('追加のリクエスト項目（JSON・任意）', _body, '{"reasoning_effort": "low"}', maxLines: 3),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'モデルは保存したあと、一覧の「モデル」から取得または追加できます。',
                style: ts(context, 9.5, color: context.c.muted, height: 1.5),
              ),
            ),
            if (_result != null) ...[
              const SizedBox(height: 10),
              Text(
                _result!,
                style: ts(
                  context,
                  10,
                  color: _result!.contains('でき') ? c.green : c.amber,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                SoftButton(
                  label: '接続を確認',
                  svg: ArceSvg.shield,
                  onTap: _busy ? null : _check,
                ),
                const SizedBox(width: 8),
                PrimaryButton(label: '保存', onTap: _busy ? null : _save),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String hint, {
    bool obscure = false,
    int maxLines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      maxLines: obscure ? 1 : maxLines,
      autocorrect: false,
      enableSuggestions: false,
      style: ts(context, 12),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

/// The models of one provider: fetch them from `/models`, add one by hand, choose the one in use.
class _ModelsSheet extends StatefulWidget {
  const _ModelsSheet({required this.app, required this.config});

  final AppController app;
  final ProviderConfig config;

  @override
  State<_ModelsSheet> createState() => _ModelsSheetState();
}

class _ModelsSheetState extends State<_ModelsSheet> {
  String? _result;
  bool _busy = false;

  ProviderConfig get _config =>
      widget.app.providers.byId(widget.config.id) ?? widget.config;

  Future<void> _fetch() async {
    setState(() {
      _busy = true;
      _result = 'モデル一覧を読み込んでいます…';
    });
    try {
      final provider = widget.app.providers.build(_config);
      final infos = provider is OpenAiCompatibleProvider
          ? await provider.fetchModelInfos()
          : const <ModelInfo>[];
      if (!mounted) return;
      final existing = {for (final model in _config.models) model.id};
      // a new model starts with what the provider says about it; one already here only gains
      // what it did not have (nothing the user typed is replaced)
      final added = [
        for (final info in infos)
          if (!existing.contains(info.id)) ModelConfig(id: info.id, name: info.id).mergeInfo(info),
      ];
      final byId = {for (final info in infos) info.id: info};
      final refreshed = [
        for (final model in _config.models)
          byId.containsKey(model.id) ? model.mergeInfo(byId[model.id]!) : model,
      ];
      final changed = [
        for (var i = 0; i < refreshed.length; i++)
          if (jsonEncode(refreshed[i].toJson()) != jsonEncode(_config.models[i].toJson())) refreshed[i],
      ];
      if (added.isNotEmpty || changed.isNotEmpty) {
        await widget.app.providers.save(
          _config.copyWith(models: [...refreshed, ...added]),
        );
      }
      if (!mounted) return;
      final withLimits = infos.where((i) => i.hasLimits).length;
      setState(
        () => _result = added.isEmpty && changed.isEmpty
            ? '新しいモデルはありませんでした（${infos.length}件）'
            : '${added.length}件のモデルを追加しました'
                '${changed.isEmpty ? '' : '、${changed.length}件の上限を更新しました'}'
                '${withLimits == 0 ? '（この提供元は上限を返しません。モデルの編集の「取得」で Hugging Face から調べられます）' : ''}',
      );
    } on AiProviderException catch (e) {
      if (mounted) setState(() => _result = e.message);
    } catch (e) {
      if (mounted) setState(() => _result = '取得できませんでした（$e）');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('モデルを追加'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'モデル名',
            hintText: 'gpt-4o-mini',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('やめる'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('追加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    if (_config.modelById(name) != null) {
      setState(() => _result = 'そのモデルはすでにあります');
      return;
    }
    await widget.app.providers.save(
      _config.copyWith(
        models: [
          ..._config.models,
          ModelConfig(id: name, name: name),
        ],
      ),
    );
    if (mounted) setState(() => _result = '$name を追加しました');
  }

  Future<void> _edit(ModelConfig model) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) =>
          _ModelEditor(app: widget.app, provider: _config, model: model),
    );
    if (mounted) setState(() {});
  }

  Future<void> _remove(ModelConfig model) async {
    final left = [
      for (final m in _config.models)
        if (m.id != model.id) m,
    ];
    await widget.app.providers.save(_config.copyWith(models: left));
    if (mounted) setState(() => _result = '${model.id} を削除しました');
  }

  Future<void> _pick(ModelConfig model) async {
    await widget.app.providers.setActiveModel(_config.id, model.id);
    widget.app.showToast('${_config.label} · ${model.id} で答えます');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = widget.app.providers;
    final models = _config.models;
    final selected = store.modelOf(_config.id)?.id;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_config.label} のモデル',
              style: ts(context, 14, weight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '選んだモデルがチャットで使われます。パラメータとプロンプトはモデルごとに保存します。',
              style: ts(context, 9.5, color: c.muted, height: 1.5),
            ),
            const SizedBox(height: 10),
            if (models.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  'モデルがまだありません。「取得」か「追加」で用意してください。',
                  style: ts(context, 10, color: c.amber, height: 1.5),
                ),
              ),
            for (var i = 0; i < models.length; i++)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  border: i == models.length - 1
                      ? null
                      : Border(bottom: BorderSide(color: c.line)),
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _pick(models[i]),
                      child: Row(
                        children: [
                          Icon(
                            selected == models[i].id
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 17,
                            color: selected == models[i].id
                                ? c.accent
                                : c.muted,
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _pick(models[i]),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              models[i].id,
                              style: ts(context, 11.5, weight: FontWeight.w600),
                            ),
                            Text(
                              _paramsLabel(models[i]),
                              style: ts(context, 9, color: c.muted),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconTap(
                      svg: ArceSvg.pencil,
                      onTap: () => _edit(models[i]),
                      tooltip: '編集',
                      size: 15,
                    ),
                    const SizedBox(width: 6),
                    IconTap(
                      svg: ArceSvg.close,
                      onTap: () => _remove(models[i]),
                      tooltip: '削除',
                      size: 15,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                SoftButton(
                  label: '取得',
                  svg: ArceSvg.retry,
                  onTap: _busy ? null : _fetch,
                ),
                const SizedBox(width: 8),
                SoftButton(
                  label: '追加',
                  svg: ArceSvg.plus,
                  onTap: _busy ? null : _add,
                ),
              ],
            ),
            if (_result != null) ...[
              const SizedBox(height: 8),
              Text(
                _result!,
                style: ts(context, 10, color: c.muted, height: 1.5),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _paramsLabel(ModelConfig model) {
    final parts = <String>[
      if (model.param('temperature') != null)
        'temperature ${model.param('temperature')}',
      if (model.param('topP') != null) 'top_p ${model.param('topP')}',
      if (model.param('maxTokens') != null)
        'max ${model.intParam('maxTokens')}',
      if (model.prompt.trim().isNotEmpty) 'プロンプトあり',
    ];
    return parts.isEmpty ? 'アプリの既定値' : parts.join(' · ');
  }
}

/// The sampling overrides and the extra prompt of one model.
class _ModelEditor extends StatefulWidget {
  const _ModelEditor({
    required this.app,
    required this.provider,
    required this.model,
  });

  final AppController app;
  final ProviderConfig provider;
  final ModelConfig model;

  @override
  State<_ModelEditor> createState() => _ModelEditorState();
}

class _ModelEditorState extends State<_ModelEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.model.name,
  );
  late final TextEditingController _temperature = TextEditingController(
    text: widget.model.param('temperature')?.toString() ?? '',
  );
  late final TextEditingController _topP = TextEditingController(
    text: widget.model.param('topP')?.toString() ?? '',
  );
  late final TextEditingController _maxTokens = TextEditingController(
    text: widget.model.intParam('maxTokens')?.toString() ?? '',
  );
  late final TextEditingController _prompt = TextEditingController(
    text: widget.model.prompt,
  );
  late final TextEditingController _context = TextEditingController(
    text: widget.model.contextTokens?.toString() ?? '',
  );
  late final TextEditingController _maxOutput = TextEditingController(
    text: widget.model.maxOutputTokens?.toString() ?? '',
  );
  String? _note;
  bool _busy = false;

  ModelHint? get _hint => ModelHints.of(widget.model.id);

  /// Starts from what the chat would do now (the saved choice, or the guess from the name).
  late bool _vision = widget.model.supportsImages;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _temperature,
      _topP,
      _maxTokens,
      _prompt,
      _context,
      _maxOutput,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final params = <String, double>{};
    final temperature = double.tryParse(_temperature.text.trim());
    final topP = double.tryParse(_topP.text.trim());
    final maxTokens = int.tryParse(_maxTokens.text.trim());
    if (temperature != null) {
      params['temperature'] = temperature.clamp(0, 2).toDouble();
    }
    if (topP != null) params['topP'] = topP.clamp(0, 1).toDouble();
    if (maxTokens != null) {
      params['maxTokens'] = maxTokens.clamp(1, 1048576).toDouble();
    }
    final model = widget.model
        .copyWith(
          name: _name.text.trim().isEmpty ? widget.model.id : _name.text.trim(),
          params: params,
          prompt: _prompt.text.trim(),
          vision: _vision,
        )
        .withLimits(contextTokens: _positive(_context.text), maxOutputTokens: _positive(_maxOutput.text));
    final provider =
        widget.app.providers.byId(widget.provider.id) ?? widget.provider;
    await widget.app.providers.save(
      provider.copyWith(
        models: [
          for (final m in provider.models)
            if (m.id == model.id) model else m,
        ],
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.app.showToast('${model.id} を保存しました');
  }

  static int? _positive(String text) {
    final value = int.tryParse(text.trim());
    return value != null && value > 0 ? value : null;
  }

  /// Asks the provider (and, for a Hugging Face name, the Hub) what the model can do, and puts the
  /// answer in the fields. Nothing is saved until the user presses 保存.
  Future<void> _fetch() async {
    setState(() {
      _busy = true;
      _note = '調べています…';
    });
    try {
      final provider = widget.app.providers.build(widget.provider, model: widget.model);
      if (provider is! OpenAiCompatibleProvider) return;
      final found = await widget.app.modelInfo.fetchFor(
        provider,
        widget.model.withLimits(),
        useHub: widget.app.settings.value.fetchModelInfoFromHub,
        overwrite: true,
      );
      if (!mounted) return;
      setState(() {
        if (found.contextTokens != null) _context.text = '${found.contextTokens}';
        if (found.maxOutputTokens != null) _maxOutput.text = '${found.maxOutputTokens}';
        if (found.vision != null) _vision = found.vision!;
        _note = found.contextTokens == null && found.maxOutputTokens == null
            ? '上限は見つかりませんでした。提供元が返さないモデルは、数字を直接入れてください'
            : '見つかりました（コンテキスト ${found.contextTokens ?? '—'}、最大出力 ${found.maxOutputTokens ?? '—'}）。保存すると反映されます';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Fills the fields with what the model's maker recommends.
  void _applyHint() {
    final hint = _hint;
    if (hint == null) return;
    setState(() {
      if (hint.temperature != null) _temperature.text = '${hint.temperature}';
      if (hint.topP != null) _topP.text = '${hint.topP}';
      if (hint.maxTokens != null) _maxTokens.text = '${hint.maxTokens}';
      if (_context.text.trim().isEmpty && hint.contextTokens != null) _context.text = '${hint.contextTokens}';
      _note = '推奨の値を入れました。保存すると反映されます';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hint = _hint;
    final shared = widget.app.settings.value;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.model.id,
              style: ts(context, 14, weight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              hint == null ? '空欄はアプリの既定値を使います。' : '空欄は、下の推奨か、アプリの既定値を使います。',
              style: ts(context, 9.5, color: c.muted),
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(hint.label, style: ts(context, 9.5, color: c.accent, height: 1.5)),
            ],
            const SizedBox(height: 10),
            _field('表示名', _name, widget.model.id),
            _field('temperature', _temperature, '${hint?.temperature ?? 0.7}'),
            _field('top_p', _topP, '${hint?.topP ?? 0.95}'),
            _field('最大トークン（1回の返信の長さ。思考の分も含みます）', _maxTokens, '${hint?.maxTokens ?? shared.maxTokens}'),
            _field('最大出力の上限（モデルが返せる最大。最大トークンはこれに収めます）', _maxOutput, '例: 65536'),
            _field('コンテキスト長（入力と出力の合計）', _context, '${hint?.contextTokens ?? '例: 131072'}'),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                SoftButton(label: '上限を取得', svg: ArceSvg.retry, onTap: _busy ? null : _fetch),
                if (hint != null) SoftButton(label: '公式の推奨を入れる', svg: ArceSvg.check, onTap: _applyHint),
              ]),
            ),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(_note!, style: ts(context, 10, color: c.muted, height: 1.5)),
              ),
            _field('追加プロンプト', _prompt, 'このモデルにだけ送る指示（任意）', maxLines: 3),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _vision,
              onChanged: (value) => setState(() => _vision = value),
              title: Text('画像を送る', style: ts(context, 12)),
              subtitle: Text(
                '添付した画像を画像のまま送ります。対応していないモデルでは、オフのままにしてください',
                style: ts(context, 9.5, color: c.muted),
              ),
            ),
            const SizedBox(height: 10),
            PrimaryButton(label: '保存', onTap: _save),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String hint, {
    int maxLines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: controller,
      maxLines: maxLines,
      autocorrect: false,
      enableSuggestions: false,
      style: ts(context, 12),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
