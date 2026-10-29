import 'package:flutter/material.dart';

import '../core/shell_secrets.dart';
import '../services/app_controller.dart';
import 'arce_text_field.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'widgets.dart';

/// The secrets a command may be given as environment variables (settings → Linux 環境). Only a name and
/// where the value comes from are settings; the value is kept in the secure storage. The model is told
/// the names, and a command gets a value only when the user approves *that command*, with the names on
/// the card.
class ShellSecretsCard extends StatelessWidget {
  const ShellSecretsCard({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: app.settings,
      builder: (context, _) {
        final secrets = app.settings.value.shellSecrets;
        return ArceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('コマンドで使う秘密', style: ts(context, 12, weight: FontWeight.w700)),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'GitHub のトークンなどを、コマンドの環境変数として渡せます（例：git push、gh、npm publish）。'
                  'モデルには名前だけを教え、値は見せません。渡すのは、モデルが `secrets` に名前を書き、'
                  'あなたがそのコマンドを承認したときだけです（毎回、カードに名前が出ます）。'
                  '注意：proot は境界ではないので、渡されたコマンドは、その値をネットワークのどこへでも送れます。'
                  '承認する前に、コマンドを読んでください。出力に値がそのまま出たときは伏せますが、'
                  '変換して出されたものは防げません。値は端末の安全な領域にだけ保存し、設定ファイル・バックアップ・チャットには入りません。'
                  'チャットからは変えられません。',
                  style: ts(context, 9.5, color: c.muted, height: 1.6),
                ),
              ),
              for (final secret in secrets) _SecretRow(app: app, secret: secret),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  SoftButton(
                    label: '秘密を追加',
                    svg: ArceSvg.plus,
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: c.surface,
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
                      builder: (context) => _SecretEditor(app: app),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SecretRow extends StatelessWidget {
  const _SecretRow({required this.app, required this.secret});

  final AppController app;
  final ShellSecret secret;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final server = secret.fromMcp
        ? app.settings.value.mcpServers.where((s) => s.id == secret.mcpServerId).map((s) => s.name.isEmpty ? s.id : s.name).firstOrNull
        : null;
    final hasValue = app.settings.shellSecretValue(secret).isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(secret.name, style: ts(context, 11.5, weight: FontWeight.w600)),
            Text(
              secret.fromMcp ? 'MCP サーバー「${server ?? secret.mcpServerId}」のトークン' : '入力した値',
              style: ts(context, 9, color: c.muted),
            ),
            if (!hasValue) Text('値がありません（モデルには教えません）', style: ts(context, 9, color: c.amber)),
          ]),
        ),
        IconTap(
          svg: ArceSvg.close,
          tooltip: '削除',
          onTap: () async {
            await app.settings.removeShellSecret(secret.name);
            app.showToast('${secret.name} を削除しました');
          },
        ),
      ]),
    );
  }
}

class _SecretEditor extends StatefulWidget {
  const _SecretEditor({required this.app});

  final AppController app;

  @override
  State<_SecretEditor> createState() => _SecretEditorState();
}

class _SecretEditorState extends State<_SecretEditor> {
  final _name = TextEditingController();
  final _value = TextEditingController();

  /// The MCP server whose token is the value; null for a value typed here.
  String? _server;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (!ShellSecrets.validName(name)) {
      widget.app.showToast('名前は英数字と _ だけ（先頭は数字以外、64 文字まで）。HOME・PATH などは使えません');
      return;
    }
    if (_server == null && _value.text.trim().isEmpty) {
      widget.app.showToast('値を入れるか、MCP サーバーのトークンを選んでください');
      return;
    }
    await widget.app.settings.setShellSecret(ShellSecret(name: name, mcpServerId: _server ?? ''), _value.text);
    if (!mounted) return;
    final app = widget.app;
    Navigator.of(context).pop();
    app.showToast('$name を保存しました');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final servers = widget.app.settings.value.mcpServers;
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: sheetBottomPadding(context)),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('秘密を追加', style: ts(context, 14, weight: FontWeight.w700)),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ArceTextField(
                controller: _name,
                style: ts(context, 12),
                decoration: const InputDecoration(
                  labelText: '環境変数の名前',
                  hintText: 'GITHUB_TOKEN',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            if (servers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DropdownButtonFormField<String?>(
                  initialValue: _server,
                  isDense: true,
                  decoration: const InputDecoration(labelText: '値のもと', isDense: true, border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('ここで入力する')),
                    for (final server in servers)
                      DropdownMenuItem<String?>(value: server.id, child: Text('MCP「${server.name.isEmpty ? server.id : server.name}」のトークン')),
                  ],
                  onChanged: (v) => setState(() => _server = v),
                ),
              ),
            if (_server == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ArceTextField(
                  controller: _value,
                  obscure: true,
                  style: ts(context, 12),
                  decoration: const InputDecoration(
                    labelText: '値',
                    hintText: '端末の安全な領域に保存します',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            Text(
              'GitHub の gh と git は GH_TOKEN / GITHUB_TOKEN を読みます。最小の権限のトークンを使ってください。',
              style: ts(context, 9, color: c.muted, height: 1.5),
            ),
            const SizedBox(height: 12),
            Row(children: [SoftButton(label: '保存', svg: ArceSvg.check, onTap: _save)]),
          ],
        ),
      ),
    );
  }
}
