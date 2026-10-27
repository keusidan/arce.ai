import 'dart:io';

import 'package:flutter/material.dart';

import '../ai/model_tree.dart';
import '../core/agents.dart';
import '../core/coding_plan.dart';
import '../core/engine.dart';
import '../services/app_controller.dart';
import '../services/settings.dart';
import 'app_scope.dart';
import 'arce_text_field.dart';
import 'mcp_widgets.dart';
import 'model_tree_view.dart';
import 'search_widgets.dart';
import 'proot_check_card.dart';
import 'provider_widgets.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'thinking_icon.dart';
import 'update_widgets.dart';
import 'widgets.dart';

/// What one group of the settings list shows when it is closed.
class _Group {
  const _Group(this.section, this.icon, this.title, this.subtitle);
  final SettingsSection section;
  final String icon;
  final String title;
  final String subtitle;
}

const _groups = [
  _Group(SettingsSection.providers, ArceSvg.cube, 'オンライン接続（プロバイダ）', 'API の接続先と、使うモデル'),
  _Group(SettingsSection.online, ArceSvg.globe, 'オンラインモデルの設定', 'temperature・最大トークン・追加プロンプト'),
  _Group(SettingsSection.local, ArceSvg.sliders, 'ローカルモデルの設定', 'サンプリング・コンテキスト長・スレッド・GPU'),
  _Group(SettingsSection.coding, ArceSvg.codeEdit, 'コーディングモード', '設計モデルが開発モデルに指示して、安く実装する'),
  _Group(SettingsSection.limits, ArceSvg.sliders2, '上限とタイムアウト', '添付・検索・通信・更新の上限と待ち時間'),
  _Group(SettingsSection.mcp, ArceSvg.bolt, 'MCP サーバー', '外部の道具（GitHub など）をつなぐ'),
  _Group(SettingsSection.basic, ArceSvg.settings, 'モデル全般設定', 'ローカルとオンライン共通：思考・回答・最大トークン・再試行'),
  _Group(SettingsSection.search, ArceSvg.search, '検索設定', '検索サーバー・検索 API・結果の件数'),
  _Group(SettingsSection.display, ArceSvg.moon, '表示・プライバシー', 'テーマ・思考中のアイコン'),
  _Group(SettingsSection.update, ArceSvg.retry, 'アップデート', '自動で更新する・確認の間隔'),
];

/// The settings, as a list of groups. A group opens downward under its own row, like a curtain,
/// and shows only its own settings; opening another one closes the first.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _keys = {for (final g in _groups) g.section: GlobalKey()};
  SettingsSection? _open;
  AppController? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = ArceScope.of(context);
    if (_app != app) {
      _app?.settingsSection.removeListener(_consume);
      _app = app..settingsSection.addListener(_consume);
      // a group may have been asked for before this page existed (the sidebar does that)
      WidgetsBinding.instance.addPostFrameCallback((_) => _consume());
    }
  }

  @override
  void dispose() {
    _app?.settingsSection.removeListener(_consume);
    super.dispose();
  }

  /// Opens the group another part of the app asked for.
  void _consume() {
    final app = _app;
    final section = app?.settingsSection.value;
    if (app == null || section == null || !mounted) return;
    app.settingsSection.value = null;
    setState(() => _open = section);
    _reveal(section);
  }

  void _toggle(SettingsSection section) {
    final opening = _open != section;
    setState(() => _open = opening ? section : null);
    if (opening) _reveal(section);
  }

  /// Scrolls so the row that was opened is at the top, once the group above it has folded.
  void _reveal(SettingsSection section) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _keys[section]?.currentContext;
      if (context == null || !context.mounted) return;
      Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return ListenableBuilder(
      listenable: app.settings,
      builder: (context, _) {
        final s = app.settings.value;
        void set(AppSettings Function(AppSettings) f) => app.settings.update(f);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
          child: PageColumn(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const PageHeading('設定', '押した項目の設定が、その下に開きます。'),
                for (final group in _groups)
                  _Curtain(
                    key: _keys[group.section],
                    group: group,
                    open: _open == group.section,
                    onTap: () => _toggle(group.section),
                    // built only while open, so a closed group costs nothing
                    body: () => _content(context, group.section, app, s, set),
                  ),
                _Footer(app: app),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _content(
    BuildContext context,
    SettingsSection section,
    AppController app,
    AppSettings s,
    void Function(AppSettings Function(AppSettings)) set,
  ) {
    switch (section) {
      case SettingsSection.providers:
        return const ProvidersSection();
      case SettingsSection.mcp:
        return const McpSection();
      case SettingsSection.online:
        return _onlineModel(s, set);
      case SettingsSection.local:
        return _localModel(app, s, set);
      case SettingsSection.coding:
        return _codingMode(app, s, set);
      case SettingsSection.limits:
        return _limits(s, set);
      case SettingsSection.basic:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArceCard(
              child: Column(
                children: [
                  SettingRow(
                    icon: ArceSvg.brainOutline,
                    title: 'Thinking 表示',
                    subtitle: '生成中の状態と思考プロセスを表示します',
                    trailing: ArceSwitch(value: s.thinking, onChanged: (v) => set((x) => x.copyWith(thinking: v))),
                  ),
                  SettingRow(
                    icon: ArceSvg.brainOutline,
                    title: '思考の内容を開いたまま表示',
                    subtitle: 'オフにすると、返信が始まったあとは折りたたみます（タップで開けます）',
                    last: true,
                    trailing: ArceSwitch(value: s.thinkingExpanded, onChanged: (v) => set((x) => x.copyWith(thinkingExpanded: v))),
                  ),
                ],
              ),
            ),
            _subheading(context, '回答（口調・速度と精度・エージェント・返信の長さ）'),
            _answerCard(context, app, s, set),
            _subheading(context, '最大トークンと再試行（共通）'),
            _developerCard(context, app, s, set),
          ],
        );
      case SettingsSection.search:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArceCard(
              child: Column(
                children: [
                  _TextRow(
                    icon: ArceSvg.globe,
                    title: 'SearXNG のアドレス',
                    subtitle: '自分の検索サーバー（先に使います）',
                    value: s.searxngUrl,
                    hint: 'http://192.168.0.10:8080',
                    onChanged: (v) => set((x) => x.copyWith(searxngUrl: v)),
                  ),
                  SettingRow(
                    icon: ArceSvg.search,
                    title: '検索結果の件数',
                    subtitle: 'Web検索で使う結果の数',
                    last: true,
                    trailing: _Cycle<int>(
                      value: s.searchResultCount,
                      values: const [3, 5, 8, 10, 15],
                      label: (v) => '$v',
                      onChanged: (v) => set((x) => x.copyWith(searchResultCount: v)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const SearchApiSection(),
          ],
        );
      case SettingsSection.display:
        return ArceCard(
          child: Column(
            children: [
              SettingRow(
                icon: ArceSvg.file,
                title: '文字の大きさ',
                subtitle: '画面全体の文字（端末の文字サイズの設定に重ねて効きます）',
                trailing: _Cycle<double>(
                  value: s.fontScale,
                  values: const [0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0],
                  label: (v) => '${(v * 100).round()}%',
                  onChanged: (v) => set((x) => x.copyWith(fontScale: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.moon,
                title: 'テーマ',
                subtitle: '画面の明るさ',
                trailing: _Dropdown<ThemeMode>(
                  value: s.theme,
                  items: const {ThemeMode.system: '端末に合わせる', ThemeMode.light: 'ライト', ThemeMode.dark: 'ダーク'},
                  onChanged: (v) => set((x) => x.copyWith(theme: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.clockCircle,
                title: 'Thinking アイコン',
                subtitle: '生成中に使う表示スタイル',
                last: true,
                trailing: const SizedBox.shrink(),
              ),
              _StyleOptions(
                current: s.thinkingStyle,
                onPick: (v) {
                  set((x) => x.copyWith(thinkingStyle: v));
                  app.showToast('Thinkingアイコンを変更しました');
                },
              ),
              const SizedBox(height: 8),
              SettingRow(
                icon: ArceSvg.shieldMinus,
                title: '端末内保存',
                subtitle: '会話とモデルはこの端末内にだけ保存されます',
                last: true,
                trailing: StatusLabel('有効', color: context.c.green, background: context.c.greenSoft),
              ),
            ],
          ),
        );
      case SettingsSection.update:
        return ArceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const UpdateCard(),
              const SizedBox(height: 6),
              const Divider(height: 24),
              SettingRow(
                icon: ArceSvg.retry,
                title: '自動で確認する',
                subtitle: '起動時と、起動中は一定時間ごとに確認します',
                trailing: ArceSwitch(value: s.autoUpdateCheck, onChanged: (v) => set((x) => x.copyWith(autoUpdateCheck: v))),
              ),
              SettingRow(
                icon: ArceSvg.bolt,
                title: '自動で更新する',
                subtitle: '見つけたらダウンロードとインストールまで自動で進めます',
                trailing: ArceSwitch(value: s.autoInstallUpdate, onChanged: (v) => set((x) => x.copyWith(autoInstallUpdate: v))),
              ),
              SettingRow(
                icon: ArceSvg.cube,
                title: '差分だけダウンロードする',
                subtitle: 'Android：今のアプリとの差分があれば、それだけ取って新しいアプリを組み立てます（なければ全体）',
                trailing: ArceSwitch(value: s.updateUseDelta, onChanged: (v) => set((x) => x.copyWith(updateUseDelta: v))),
              ),
              SettingRow(
                icon: ArceSvg.clock,
                title: '確認の間隔',
                subtitle: '時間',
                trailing: _Cycle<int>(
                  value: s.updateIntervalHours,
                  values: const [1, 6, 12, 24, 72],
                  label: (v) => '$v 時間',
                  onChanged: (v) => set((x) => x.copyWith(updateIntervalHours: v)),
                ),
              ),
              _TextRow(
                icon: ArceSvg.globe,
                title: 'リポジトリ',
                subtitle: '更新を探す GitHub のリポジトリ（owner/name）',
                value: s.updateRepo,
                hint: AppSettings.defaultRepo,
                onChanged: (v) => set((x) => x.copyWith(updateRepo: v.trim())),
              ),
              _TextRow(
                icon: ArceSvg.shield,
                title: 'GitHub トークン',
                subtitle: '非公開リポジトリのときだけ。この端末の安全な領域に保存します',
                value: app.settings.githubToken,
                hint: 'github_pat_…',
                obscure: true,
                last: true,
                onChanged: app.settings.setGithubToken,
              ),
            ],
          ),
        );
    }
  }

  Widget _subheading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(text, style: ts(context, 11, weight: FontWeight.w700, color: context.c.muted)),
      );

  Widget _answerCard(
    BuildContext context,
    AppController app,
    AppSettings s,
    void Function(AppSettings Function(AppSettings)) set,
  ) {
        return ArceCard(
          child: Column(
            children: [
              _TextRow(
                icon: ArceSvg.chat,
                title: '口調',
                subtitle: '回答の話し方（200文字まで）。ルールは変えられません',
                value: s.tone,
                hint: '例: 丁寧で簡潔に',
                onChanged: (v) => set((x) => x.copyWith(tone: v)),
              ),
              _SliderRow(
                icon: ArceSvg.sliders,
                title: '速度 ⇔ 精度',
                subtitle: '左: 速い（思考を省略） / 右: 正確（長く考える）',
                value: s.speedAccuracy,
                onChanged: (v) => set((x) => x.copyWith(speedAccuracy: v)),
              ),
              SettingRow(
                icon: ArceSvg.compass,
                title: 'エージェント',
                subtitle: '用途に合わせた役割。自動のときは内容から選びます',
                trailing: _Dropdown<String>(
                  value: s.agentOverride,
                  items: {'': '自動', for (final a in Agents.all) a.id: a.displayName},
                  onChanged: (v) => set((x) => x.copyWith(agentOverride: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.brainOutline,
                title: 'AIによるエージェント選択',
                subtitle: '判断に迷うときだけ読み込み済みモデルに選ばせます',
                trailing: ArceSwitch(value: s.aiAgentSelection, onChanged: (v) => set((x) => x.copyWith(aiAgentSelection: v))),
              ),
              SettingRow(
                icon: ArceSvg.file,
                title: '返信の最大文字数',
                subtitle: '0 は制限なし',
                last: true,
                trailing: _Cycle<int>(
                  value: s.maxChars,
                  values: const [0, 300, 800, 1500, 3000],
                  label: (v) => v == 0 ? '制限なし' : '$v',
                  onChanged: (v) => set((x) => x.copyWith(maxChars: v)),
                ),
              ),
            ],
          ),
        );
  }

  Widget _developerCard(
    BuildContext context,
    AppController app,
    AppSettings s,
    void Function(AppSettings Function(AppSettings)) set,
  ) {
        return ArceCard(
          child: Column(
            children: [
              SettingRow(
                icon: ArceSvg.file,
                title: '最大トークン数（共通）',
                subtitle: '1回の返信の長さの目安（思考の分も含みます）。ローカル・オンラインで別に決めたとき、'
                    'また DeepSeek V4・GLM-5 のように公式の推奨があるモデルでは、そちらが先です',
                trailing: _Cycle<int>(
                  value: s.maxTokens,
                  values: const [1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144],
                  label: (v) => '$v',
                  onChanged: (v) => set((x) => x.copyWith(maxTokens: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.retry,
                title: 'エラー再書き込み回数',
                subtitle: '途中で切れたツール呼び出しを書き直す回数',
                trailing: _Cycle<int>(
                  value: s.retryLimit,
                  values: const [0, 1, 2, 3],
                  label: (v) => '$v',
                  onChanged: (v) => set((x) => x.copyWith(retryLimit: v)),
                ),
              ),
              SettingRow(
                icon: ArceSvg.bolt,
                title: 'ツール呼び出しの上限',
                subtitle: '1回の返信の中で使えるツールの回数の上限です。引数が違う呼び出し（別の言葉での検索など）は、繰り返しとはみなしません',
                last: true,
                trailing: _Cycle<int>(
                  value: s.maxToolRounds,
                  values: const [2, 6, 10, 20, 30, 100, 0],
                  label: (v) => v == 0 ? 'なし' : '$v',
                  onChanged: (v) => set((x) => x.copyWith(maxToolRounds: v)),
                ),
              ),
            ],
          ),
        );
  }

  /// A decimal field that reads "not set" as -1, so an empty box means "the app's own value".
  Widget _decimal({
    required String icon,
    required String title,
    required String subtitle,
    required double value,
    required String hint,
    required double max,
    required void Function(double) onChanged,
    bool last = false,
  }) => _TextRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    value: value < 0 ? '' : '$value',
    hint: hint,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    last: last,
    onChanged: (v) {
      final parsed = double.tryParse(v.trim());
      onChanged(parsed == null ? -1 : parsed.clamp(0, max).toDouble());
    },
  );

  /// A whole-number field that reads "not set" as 0.
  Widget _whole({
    required String icon,
    required String title,
    required String subtitle,
    required int value,
    required String hint,
    required int max,
    required void Function(int) onChanged,
    bool last = false,
  }) => _TextRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    value: value <= 0 ? '' : '$value',
    hint: hint,
    keyboardType: TextInputType.number,
    last: last,
    onChanged: (v) {
      final parsed = int.tryParse(v.trim());
      onChanged(parsed == null ? 0 : parsed.clamp(0, max));
    },
  );

  Widget _limits(AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    Widget cycle(
      String icon,
      String title,
      String subtitle,
      int value,
      List<int> values,
      AppSettings Function(AppSettings, int) apply, {
      String unit = '',
      bool last = false,
    }) => SettingRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      last: last,
      trailing: _Cycle<int>(value: value, values: values, label: (v) => '$v$unit', onChanged: (v) => set((x) => apply(x, v))),
    );
    return ArceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '押すと次の値になります。ほかの値は、チャットで「添付の文字数を 20000 にして」のように頼めます。',
              style: ts(context, 10, color: context.c.muted, height: 1.6),
            ),
          ),
          cycle(ArceSvg.paperclip, '添付できるファイルの数', '1回のメッセージに付けられる数', s.attachMaxFiles, const [1, 3, 5, 10, 20],
              (x, v) => x.copyWith(attachMaxFiles: v)),
          cycle(ArceSvg.file, '添付1ファイルから読む文字数', 'これを超えた分は省略されます', s.attachCharsPerFile, const [2000, 4000, 8000, 16000, 32000],
              (x, v) => x.copyWith(attachCharsPerFile: v)),
          cycle(ArceSvg.file, '添付全体で読む文字数', 'コンテキストを使い切らないための上限', s.attachTotalChars, const [8000, 16000, 32000, 64000, 128000],
              (x, v) => x.copyWith(attachTotalChars: v)),
          cycle(ArceSvg.eye, '送る画像の大きさ', '画像に対応するモデルへ送る1枚の上限', s.attachImageMb, const [1, 2, 4, 8, 16],
              (x, v) => x.copyWith(attachImageMb: v), unit: ' MB'),
          cycle(ArceSvg.clock, '検索・天気のタイムアウト', 'この秒数で通信をあきらめます', s.httpTimeoutSeconds, const [10, 20, 30, 60],
              (x, v) => x.copyWith(httpTimeoutSeconds: v), unit: ' 秒'),
          cycle(ArceSvg.bolt, 'MCPサーバーのタイムアウト', '道具の呼び出しを待つ時間', s.mcpTimeoutSeconds, const [20, 40, 60, 120],
              (x, v) => x.copyWith(mcpTimeoutSeconds: v), unit: ' 秒'),
          cycle(ArceSvg.bolt, 'MCP の結果の上限', 'MCP の道具の結果を、モデルに渡す文字数（超えた分は省きます。画像などのファイルは、中身ではなく説明を渡します）', s.mcpResultMaxChars, const [5000, 15000, 30000, 100000],
              (x, v) => x.copyWith(mcpResultMaxChars: v), unit: ' 文字'),
          cycle(ArceSvg.cube, 'オンラインモデルの応答のタイムアウト', '最初の応答までに待つ時間', s.providerTimeoutSeconds, const [30, 60, 120, 300, 600],
              (x, v) => x.copyWith(providerTimeoutSeconds: v), unit: ' 秒'),
          cycle(ArceSvg.retry, 'ツールの繰り返しで止める回数', '同じ道具を同じ引数で、この回数呼んだら、ループとみなして止めます（引数が違えば数えません）', s.toolRepeatLimit, const [2, 3, 4, 5],
              (x, v) => x.copyWith(toolRepeatLimit: v)),
          cycle(ArceSvg.retry, 'ダウンロードの試行回数', '通信が切れたとき、続きから取り直す回数（モデルも更新も）', s.updateRetryAttempts, const [1, 3, 5, 10],
              (x, v) => x.copyWith(updateRetryAttempts: v)),
          cycle(ArceSvg.clock, 'ダウンロードの無通信の判定', 'この秒数なにも届かなければ、切れたとみなします', s.updateStallSeconds, const [15, 30, 60, 120],
              (x, v) => x.copyWith(updateStallSeconds: v), unit: ' 秒'),
          cycle(ArceSvg.bolt, 'ダウンロードの同時接続数', '大きなファイルを分けて同時に取ります。遅いときに増やします（1で分けない）', s.downloadConnections, const [1, 2, 4, 8, 16],
              (x, v) => x.copyWith(downloadConnections: v)),
          SettingRow(
            icon: ArceSvg.retry,
            title: '止まったダウンロードを次の起動で続ける',
            subtitle: 'アプリを閉じて止まったモデルのダウンロードを、起動したときに続きから取ります（モバイル回線でも始まります）',
            last: true,
            trailing: ArceSwitch(value: s.resumeDownloadsOnStart, onChanged: (v) => set((x) => x.copyWith(resumeDownloadsOnStart: v))),
          ),
        ],
      ),
    );
  }

  Widget _codingMode(AppController app, AppSettings s, void Function(AppSettings Function(AppSettings)) set) {
    final c = context.c;
    final coding = s.coding;
    final String? problem;
    if (!coding.enabled) {
      problem = null;
    } else if (coding.planner.isEmpty || coding.developer.isEmpty) {
      problem = '設計モデルと開発モデルの両方を選ぶと、分担が始まります。';
    } else if ((coding.planner.startsWith('${CodingSettings.localProvider}|') ||
            coding.developer.startsWith('${CodingSettings.localProvider}|')) &&
        !app.models.isLoaded) {
      problem = '端末のモデルを選んでいますが、まだ読み込まれていません。読み込むまで、いつもどおり1つのモデルで答えます。';
    } else {
      problem = null;
    }
    Widget pick(String icon, String title, String subtitle, String value, void Function(String) onPick) => SettingRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: _ModelRefField(app: app, value: value, title: title, width: 168, onChanged: onPick),
    );
    return ArceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Coding エージェントのとき、高性能な「設計モデル」が依頼をタスクに分け、安い「開発モデル」が同時に実装します。'
              '設計モデルは短い計画とレビューだけを書くので、長いコードの費用を抑えられます。端末のモデルも選べます（その役は1つずつ動きます）。',
              style: ts(context, 10, color: c.muted, height: 1.6),
            ),
          ),
          SettingRow(
            icon: ArceSvg.codeEdit,
            title: 'コーディングモード',
            subtitle: '設計モデルと開発モデルで分担します',
            trailing: ArceSwitch(value: s.codingPlanEnabled, onChanged: (v) => set((x) => x.copyWith(codingPlanEnabled: v))),
          ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(problem, style: ts(context, 10, color: c.amber, height: 1.6)),
            ),
          pick(ArceSvg.compass, '設計モデル', '依頼を分けて、結果をレビューします（高性能なモデル向き）', s.plannerModel,
              (v) => set((x) => x.copyWith(plannerModel: v))),
          pick(ArceSvg.bolt, '開発モデル', 'コードを書きます（安いモデル・端末のモデル向き）', s.developerModel,
              (v) => set((x) => x.copyWith(developerModel: v))),
          SettingRow(
            icon: ArceSvg.grid,
            title: 'タスクの最大数',
            subtitle: '依頼をいくつまでに分けるか',
            trailing: _Cycle<int>(
              value: coding.maxTasks,
              values: const [1, 2, 3, 4, 6, 8],
              label: (v) => '$v',
              onChanged: (v) => set((x) => x.copyWith(codingMaxTasks: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.sliders2,
            title: '同時に走らせる数',
            subtitle: '開発モデルへの同時リクエスト数（端末のモデルは常に1）',
            trailing: _Cycle<int>(
              value: coding.parallel,
              values: const [1, 2, 3, 4, 6, 8],
              label: (v) => '$v',
              onChanged: (v) => set((x) => x.copyWith(codingParallel: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.retry,
            title: 'レビューの回数',
            subtitle: '設計モデルが書き直しを指示できる回数。0 ならレビューしません',
            trailing: _Cycle<int>(
              value: coding.reviewRounds,
              values: const [0, 1, 2, 3],
              label: (v) => '$v',
              onChanged: (v) => set((x) => x.copyWith(codingReviewRounds: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.file,
            title: '設計モデルの最大トークン',
            subtitle: '計画とレビューの長さ。自動は、モデルの推奨と上限に合わせます',
            trailing: _Cycle<int>(
              value: coding.plannerMaxTokens,
              values: const [0, 4096, 8192, 16384, 32768, 65536, 131072, 262144],
              label: (v) => v == 0 ? '自動' : '$v',
              onChanged: (v) => set((x) => x.copyWith(codingPlannerMaxTokens: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.file,
            title: '開発モデルの最大トークン',
            subtitle: '1つのタスクのコードの長さ（思考の分も含みます）。自動は、モデルの推奨と上限に合わせます',
            last: true,
            trailing: _Cycle<int>(
              value: coding.developerMaxTokens,
              values: const [0, 8192, 16384, 32768, 65536, 131072, 262144],
              label: (v) => v == 0 ? '自動' : '$v',
              onChanged: (v) => set((x) => x.copyWith(codingDeveloperMaxTokens: v)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _onlineModel(AppSettings s, void Function(AppSettings Function(AppSettings)) set) => ArceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'オンラインのモデルだけに効く既定値です（端末のモデルは別。次の「ローカルモデルの設定」）。'
            'モデルごとの設定（プロバイダ → モデル → 編集）があれば、そちらが先です。空欄はアプリの既定値です。',
            style: ts(context, 10, color: context.c.muted, height: 1.6),
          ),
        ),
        _decimal(
          icon: ArceSvg.sliders,
          title: 'temperature',
          subtitle: '大きいほど表現がばらつきます（0〜2）',
          value: s.onlineTemperature,
          hint: '0.7',
          max: 2,
          onChanged: (v) => set((x) => x.copyWith(onlineTemperature: v)),
        ),
        _decimal(
          icon: ArceSvg.sliders2,
          title: 'top_p',
          subtitle: '選ぶ言葉の範囲（0〜1）',
          value: s.onlineTopP,
          hint: '0.95',
          max: 1,
          onChanged: (v) => set((x) => x.copyWith(onlineTopP: v)),
        ),
        _whole(
          icon: ArceSvg.file,
          title: '最大トークン',
          subtitle: '1回の返信の長さの基準（思考の分も含みます）。空欄は、モデルの推奨か共通の値',
          value: s.onlineMaxTokens,
          hint: '${s.maxTokens}',
          max: 1048576,
          onChanged: (v) => set((x) => x.copyWith(onlineMaxTokens: v)),
        ),
        _TextRow(
          icon: ArceSvg.chat,
          title: '追加プロンプト',
          subtitle: 'オンラインのモデルにだけ送る指示（2000文字まで）',
          value: s.onlinePrompt,
          hint: '例: 回答は必ず日本語で',
          maxLines: 3,
          onChanged: (v) => set((x) => x.copyWith(onlinePrompt: v)),
        ),
        SettingRow(
          icon: ArceSvg.retry,
          title: 'モデルの上限を自動で調べる',
          subtitle: '使い始めたモデルのコンテキスト長・最大出力・画像対応を、提供元のモデル一覧から調べて保存します',
          trailing: ArceSwitch(value: s.autoFetchModelInfo, onChanged: (v) => set((x) => x.copyWith(autoFetchModelInfo: v))),
        ),
        SettingRow(
          icon: ArceSvg.globe,
          title: 'Hugging Face からも調べる',
          subtitle: '提供元が上限を返さないとき、モデル名（owner/name）だけを huggingface.co に送って、'
              'コンテキスト長を読みます',
          last: true,
          trailing: ArceSwitch(
            value: s.fetchModelInfoFromHub,
            onChanged: (v) => set((x) => x.copyWith(fetchModelInfoFromHub: v)),
          ),
        ),
      ],
    ),
  );

  Widget _localModel(AppController app, AppSettings s, void Function(AppSettings Function(AppSettings)) set) => ArceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '端末のモデル（Android）だけに効く設定です。オンラインのモデルは別（上の「オンラインモデルの設定」）。'
            '空欄はアプリの既定値です。コンテキスト長・スレッド・GPU・KV キャッシュは、次にモデルを読み込むときに反映されます。',
            style: ts(context, 10, color: context.c.muted, height: 1.6),
          ),
        ),
        _decimal(
          icon: ArceSvg.sliders,
          title: 'temperature',
          subtitle: '大きいほど表現がばらつきます（0〜2）',
          value: s.localTemperature,
          hint: '0.6 / 0.7（思考の有無で変わります）',
          max: 2,
          onChanged: (v) => set((x) => x.copyWith(localTemperature: v)),
        ),
        _decimal(
          icon: ArceSvg.sliders2,
          title: 'top_p',
          subtitle: '選ぶ言葉の範囲（0〜1）',
          value: s.localTopP,
          hint: '0.95 / 0.8',
          max: 1,
          onChanged: (v) => set((x) => x.copyWith(localTopP: v)),
        ),
        _whole(
          icon: ArceSvg.sliders,
          title: 'top_k',
          subtitle: '候補にする言葉の数（0 は既定）',
          value: s.localTopK,
          hint: '20',
          max: 200,
          onChanged: (v) => set((x) => x.copyWith(localTopK: v)),
        ),
        _decimal(
          icon: ArceSvg.sliders2,
          title: 'min_p',
          subtitle: '確率がこれ未満の言葉を除きます（0〜1）',
          value: s.localMinP,
          hint: '0',
          max: 1,
          onChanged: (v) => set((x) => x.copyWith(localMinP: v)),
        ),
        _decimal(
          icon: ArceSvg.retry,
          title: 'DRY（繰り返しの抑制）',
          subtitle: '大きいほど、同じ言い回しの繰り返しを避けます（0 でオフ）',
          value: s.localDryMultiplier,
          hint: '0.8',
          max: 5,
          onChanged: (v) => set((x) => x.copyWith(localDryMultiplier: v)),
        ),
        _whole(
          icon: ArceSvg.file,
          title: '最大トークン',
          subtitle: '1回の返信の長さの基準。空欄は共通の値',
          value: s.localMaxTokens,
          hint: '${s.maxTokens}',
          max: 32768,
          onChanged: (v) => set((x) => x.copyWith(localMaxTokens: v)),
        ),
        _TextRow(
          icon: ArceSvg.chat,
          title: '追加プロンプト',
          subtitle: '端末のモデルにだけ送る指示（2000文字まで）',
          value: s.localPrompt,
          hint: '例: 簡潔に答えてください',
          maxLines: 3,
          onChanged: (v) => set((x) => x.copyWith(localPrompt: v)),
        ),
        SettingRow(
          icon: ArceSvg.sliders,
          title: 'Context Length',
          subtitle: 'モデルが一度に扱う長さ。大きいほどメモリを使います',
          trailing: _Cycle<int>(
            value: s.contextLength,
            values: const [2048, 4096, 8192, 16384],
            label: (v) => '$v',
            onChanged: (v) => set((x) => x.copyWith(contextLength: v)),
          ),
        ),
        SettingRow(
          icon: ArceSvg.sliders2,
          title: 'CPU Threads',
          subtitle: 'Auto は端末のコア数から決めます',
          trailing: _Cycle<int>(
            value: s.threads,
            values: const [0, 1, 2, 4, 8],
            label: (v) => v == 0 ? 'Auto' : '$v',
            onChanged: (v) => set((x) => x.copyWith(threads: v)),
          ),
        ),
        SettingRow(
          icon: ArceSvg.bolt,
          title: 'HyperLoad',
          subtitle: 'CPUを使い切って高速化します（発熱・消費電力が増えます）',
          trailing: ArceSwitch(value: s.hyperLoad, onChanged: (v) => set((x) => x.copyWith(hyperLoad: v))),
        ),
        SettingRow(
          icon: ArceSvg.compass,
          title: 'GPU オフロード',
          subtitle: 'GPU に任せる量（対応する端末のみ）',
          trailing: _Dropdown<GpuOffload>(
            value: s.gpuOffload,
            items: const {
              GpuOffload.auto: 'Auto',
              GpuOffload.cpuOnly: 'CPUのみ',
              GpuOffload.gpuPriority: 'GPU優先',
              GpuOffload.maxGpu: '最大',
            },
            onChanged: (v) => set((x) => x.copyWith(gpuOffload: v)),
          ),
        ),
        SettingRow(
          icon: ArceSvg.sliders,
          title: 'KV キャッシュ',
          subtitle: 'Q8_0 でメモリが約半分、Q4_0 で約3分の1。小さいほど精度は少し落ちます',
          trailing: _Cycle<KvCacheType>(
            value: s.kvCache,
            values: KvCacheType.values,
            label: (v) => switch (v) {
              KvCacheType.f16 => 'F16',
              KvCacheType.q8_0 => 'Q8_0',
              KvCacheType.q4_0 => 'Q4_0',
            },
            onChanged: (v) => set((x) => x.copyWith(kvCache: v)),
          ),
        ),
        SettingRow(
          icon: ArceSvg.file,
          title: 'KV キャッシュをファイルに保存',
          subtitle: '会話の途中までの計算結果を保存し、開き直したときの待ち時間を省きます'
              '（Android の llama.cpp のみ。1つの会話で数百MBになることがあります）',
          last: !s.kvSnapshotEnabled,
          trailing: ArceSwitch(
            value: s.kvSnapshotEnabled,
            onChanged: (v) {
              set((x) => x.copyWith(kvSnapshotEnabled: v));
              // off means the files are not wanted any more
              if (!v) app.clearKvSnapshots();
            },
          ),
        ),
        if (s.kvSnapshotEnabled) ...[
          SettingRow(
            icon: ArceSvg.file,
            title: '保存の上限（合計）',
            subtitle: '超えたら、いちばん長く使っていない会話の分から消します',
            trailing: _Cycle<int>(
              value: s.kvSnapshotMaxMb,
              values: const [256, 512, 1024, 2048, 4096],
              label: (v) => '$v MB',
              onChanged: (v) => set((x) => x.copyWith(kvSnapshotMaxMb: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.sliders,
            title: '保存する最小の長さ',
            subtitle: 'これより短いプロンプトは、計算し直すほうが速いので保存しません',
            trailing: _Cycle<int>(
              value: s.kvSnapshotMinTokens,
              values: const [256, 512, 1024, 2048],
              label: (v) => '$v トークン',
              onChanged: (v) => set((x) => x.copyWith(kvSnapshotMinTokens: v)),
            ),
          ),
          SettingRow(
            icon: ArceSvg.close,
            title: '保存済みのキャッシュ',
            subtitle: app.canSaveKv
                ? '合計 ${(app.kvSnapshotBytes / 1048576).toStringAsFixed(1)} MB'
                : 'この端末（OS）では保存できません',
            last: true,
            trailing: SoftButton(label: 'すべて削除', onTap: app.clearKvSnapshots),
          ),
        ],
        SettingRow(
          icon: ArceSvg.alert,
          title: 'Force Execution',
          subtitle: 'メモリ不足の警告があっても、モデルの選択を許可します',
          last: !Platform.isAndroid,
          trailing: ArceSwitch(value: s.forceExecution, onChanged: (v) => set((x) => x.copyWith(forceExecution: v))),
        ),
        if (Platform.isAndroid) ProotCheckRow(app: app),
      ],
    ),
  );
}

/// One row of the settings list with its group hanging below it while it is open.
class _Curtain extends StatelessWidget {
  const _Curtain({super.key, required this.group, required this.open, required this.onTap, required this.body});

  final _Group group;
  final bool open;
  final VoidCallback onTap;
  final Widget Function() body;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ArceCard(
          padding: EdgeInsets.zero,
          margin: EdgeInsets.only(bottom: open ? 8 : 11),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
                child: Row(
                  children: [
                    Container(
                      width: 31,
                      height: 31,
                      decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(10)),
                      alignment: Alignment.center,
                      child: ArceIcon(group.icon, size: 16, color: c.accent),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(group.title, style: ts(context, 13, weight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(group.subtitle, style: ts(context, 10.5, color: c.muted, height: 1.4)),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: open ? .5 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: ArceIcon(ArceSvg.chevronDown, size: 15, color: open ? c.accent : c.faint),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open ? body() : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 11, 3, 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('ARCE.AI · ローカルAI', style: ts(context, 9, color: c.muted)),
          ListenableBuilder(
            listenable: app.updates,
            builder: (context, _) => Text(
              'v${app.updates.currentVersion ?? '—'}',
              style: ts(context, 9, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _StyleOptions extends StatelessWidget {
  const _StyleOptions({required this.current, required this.onPick});
  final ThinkingStyle current;
  final ValueChanged<ThinkingStyle> onPick;

  static const _names = {
    ThinkingStyle.basic: '基本',
    ThinkingStyle.ring: 'リング',
    ThinkingStyle.pulse: 'パルス',
    ThinkingStyle.dots: 'ドット',
    ThinkingStyle.rotation: 'ローテーション',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 7,
        runSpacing: 7,
        children: [
          for (final style in ThinkingStyle.values)
            SizedBox(
              width: 92,
              child: Material(
                color: style == current ? c.accentSoft : c.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11),
                  side: BorderSide(color: style == current ? c.accent : c.line),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(11),
                  onTap: () => onPick(style),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 30,
                          child: Center(
                            child: ThinkingIcon(style: style, size: 25),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _names[style]!,
                          style: ts(
                            context,
                            9,
                            color: style == current ? c.accent : c.muted,
                            weight: style == current
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tapping steps to the next value, like the pill buttons of the original interface.
class _Cycle<T> extends StatelessWidget {
  const _Cycle({
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });
  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final i = values.indexOf(value);
    return ValuePill(
      label(value),
      onTap: () => onChanged(values[(i + 1) % values.length]),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
  });
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: items.containsKey(value) ? value : items.keys.first,
          isDense: true,
          dropdownColor: c.surface,
          icon: ArceIcon(ArceSvg.chevronDown, size: 14, color: c.muted),
          style: ts(context, 10, weight: FontWeight.w600),
          items: [
            for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

/// The choice of a model for a job (a provider's model, the device model, or none): the field
/// shows the choice, and a tap opens a full-height tree with a search field. The models used last
/// are at the top, so the ones in use are one tap away.
class _ModelRefField extends StatelessWidget {
  const _ModelRefField({
    required this.app,
    required this.value,
    required this.onChanged,
    required this.title,
    required this.width,
  });
  final AppController app;
  final String value;
  final ValueChanged<String> onChanged;
  final String title;
  final double width;

  static const _roots = [
    TreeLeaf('', '未選択'),
    TreeLeaf('${CodingSettings.localProvider}|', '端末のモデル'),
  ];

  String _label() {
    if (value.isEmpty) return '未選択';
    final parsed = CodingSettings.parseRef(value);
    if (parsed == null) return value;
    final (providerId, model) = parsed;
    if (providerId == CodingSettings.localProvider) return '端末のモデル';
    final provider = app.providers.byId(providerId);
    return '${provider == null ? providerId : (provider.label.isEmpty ? provider.id : provider.label)} · $model';
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModelPicker(
      context,
      title: title,
      selectedKey: value,
      note: '提供元ごとに分かれています。上の「最近使った」から選ぶと早く決められます。検索は提供元の名前でも絞れます',
      build: (query) => ModelTrees.forPicker(
        app.providers.providers,
        query: query,
        recent: app.providers.recentRefs,
        rootLeaves: _roots,
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _open(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.line),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(_label(), maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(context, 10, weight: FontWeight.w600)),
              ),
              const SizedBox(width: 4),
              ArceIcon(ArceSvg.chevronDown, size: 14, color: c.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String icon;
  final String title;
  final String subtitle;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 1),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 31,
                height: 31,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: ArceIcon(icon, size: 16, color: c.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: ts(context, 11, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: ts(context, 9, color: c.muted, height: 1.45),
                    ),
                  ],
                ),
              ),
              Text(
                '${(value * 100).round()}%',
                style: ts(context, 10, weight: FontWeight.w600),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(value: value, onChanged: onChanged, divisions: 20),
          ),
        ],
      ),
    );
  }
}

class _TextRow extends StatefulWidget {
  const _TextRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.hint,
    required this.onChanged,
    this.obscure = false,
    this.last = false,
    this.keyboardType,
    this.maxLines = 1,
  });

  final String icon;
  final String title;
  final String subtitle;
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;
  final bool obscure;
  final bool last;
  final TextInputType? keyboardType;
  final int maxLines;

  @override
  State<_TextRow> createState() => _TextRowState();
}

class _TextRowState extends State<_TextRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 1),
      decoration: BoxDecoration(
        border: widget.last ? null : Border(bottom: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 31,
                height: 31,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: ArceIcon(widget.icon, size: 16, color: c.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: ts(context, 11, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.subtitle,
                      style: ts(context, 9, color: c.muted, height: 1.45),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ArceTextField(
            controller: _controller,
            obscure: widget.obscure,
            keyboardType: widget.keyboardType,
            maxLines: widget.maxLines,
            style: ts(context, 11.5),
            onChanged: widget.onChanged,
            decoration: InputDecoration(
              isDense: true,
              hintText: widget.hint,
              hintStyle: ts(context, 11.5, color: c.faint),
              filled: true,
              fillColor: c.surface2,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(color: c.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(color: c.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(color: c.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
