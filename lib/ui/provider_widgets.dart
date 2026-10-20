import 'package:flutter/material.dart';

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
          child: Column(children: [
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
                title: providers[i].label.isEmpty ? providers[i].id : providers[i].label,
                detail: '${providers[i].model} · ${providers[i].baseUrl}',
                selected: store.activeId == providers[i].id,
                badge: !store.hasKey(providers[i].id)
                    ? 'APIキー未設定'
                    : (store.activeId == providers[i].id ? '使用中' : null),
                onPick: () => app.setActiveProvider(providers[i].id),
                onEdit: () => _openEditor(context, app, providers[i]),
                onDelete: () => _confirmDelete(context, app, providers[i]),
                last: i == providers.length - 1,
              ),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                SoftButton(
                  label: 'プロバイダを追加',
                  svg: ArceSvg.plus,
                  onTap: () => _openEditor(context, app, null),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'OpenAI 互換の API ならどれでも使えます（OpenAI、Groq、OpenRouter、Ollama、LM Studio など）。'
                'Base URL は /chat/completions より前までです。',
                style: ts(context, 9, color: context.c.muted, height: 1.5),
              ),
            ),
          ]),
        );
      },
    );
  }

  static Future<void> _confirmDelete(BuildContext context, AppController app, ProviderConfig config) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(config.label.isEmpty ? config.id : config.label),
        content: const Text('このプロバイダと、保存したAPIキーを削除します。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('やめる')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('削除')),
        ],
      ),
    );
    if (ok != true) return;
    await app.providers.remove(config.id);
    await app.setActiveProvider(app.providers.activeId);
    app.showToast('削除しました');
  }

  static Future<void> _openEditor(BuildContext context, AppController app, ProviderConfig? existing) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (context) => _ProviderEditor(app: app, store: app.providers, existing: existing),
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
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 1),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: c.line))),
      child: Row(children: [
        ArceIcon(icon, size: 16, color: selected ? c.accent : c.muted),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPick,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: ts(context, 12, weight: FontWeight.w700, color: selected ? c.accent : c.ink),
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
              ]),
              const SizedBox(height: 2),
              Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(context, 9, color: c.muted)),
            ]),
          ),
        ),
        if (onEdit != null) ...[
          const SizedBox(width: 6),
          IconTap(svg: ArceSvg.pencil, onTap: onEdit!, tooltip: '編集', size: 16),
        ],
        if (onDelete != null) ...[
          const SizedBox(width: 6),
          SoftButton(label: '削除', height: 28, onTap: onDelete),
        ],
        if (onEdit == null) ...[
          const SizedBox(width: 8),
          StatusLabel(selected ? '選択中' : '選ぶ', color: selected ? c.accent : c.muted),
        ],
      ]),
    );
  }
}

/// Add or edit one provider; the connection check uses what is typed, not what was saved.
class _ProviderEditor extends StatefulWidget {
  const _ProviderEditor({required this.app, required this.store, this.existing});

  final AppController app;
  final ProviderStore store;
  final ProviderConfig? existing;

  @override
  State<_ProviderEditor> createState() => _ProviderEditorState();
}

class _ProviderEditorState extends State<_ProviderEditor> {
  late final TextEditingController _label = TextEditingController(text: widget.existing?.label ?? '');
  late final TextEditingController _baseUrl = TextEditingController(text: widget.existing?.baseUrl ?? '');
  late final TextEditingController _model = TextEditingController(text: widget.existing?.model ?? '');
  late final TextEditingController _key = TextEditingController(
    text: widget.existing == null ? '' : widget.store.keyOf(widget.existing!.id),
  );

  String? _result;
  bool _busy = false;

  @override
  void dispose() {
    for (final controller in [_label, _baseUrl, _model, _key]) {
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
      model: _model.text.trim(),
      headers: existing?.headers ?? const {},
      body: existing?.body ?? const {},
      supportsTools: existing?.supportsTools ?? true,
    );
  }

  Future<void> _check() async {
    final config = _config();
    if (!config.isComplete) {
      setState(() => _result = 'Base URL（https://…）とモデル名を入れてください');
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
      model: config.model,
      apiKey: _key.text.trim(),
      headers: config.headers,
      body: config.body,
      supportsTools: config.supportsTools,
    );
    try {
      await provider.verify();
      if (!mounted) return;
      setState(() => _result = '接続できました（${config.model}）');
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
    final config = _config();
    if (!config.isComplete) {
      setState(() => _result = 'Base URL（https://…）とモデル名を入れてください');
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
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(editing ? 'プロバイダを編集' : 'プロバイダを追加', style: ts(context, 14, weight: FontWeight.w700)),
          const SizedBox(height: 12),
          _field('名前', _label, '例: OpenAI / Groq / 自宅の Ollama'),
          _field('Base URL', _baseUrl, 'https://api.openai.com/v1'),
          _field('モデル', _model, 'gpt-4o-mini'),
          _field('APIキー', _key, 'sk-…（端末の安全な領域に保存します）', obscure: true),
          if (_result != null) ...[
            const SizedBox(height: 10),
            Text(
              _result!,
              style: ts(context, 10, color: _result!.contains('でき') ? c.green : c.amber, height: 1.5),
            ),
          ],
          const SizedBox(height: 14),
          Row(children: [
            SoftButton(label: '接続を確認', svg: ArceSvg.shield, onTap: _busy ? null : _check),
            const SizedBox(width: 8),
            PrimaryButton(label: '保存', onTap: _busy ? null : _save),
          ]),
        ]),
      ),
    );
  }

  Widget _field(String label, TextEditingController controller, String hint, {bool obscure = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: controller,
          obscureText: obscure,
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
