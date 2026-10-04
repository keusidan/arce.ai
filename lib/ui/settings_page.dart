import 'package:flutter/material.dart';

import '../core/agents.dart';
import '../core/engine.dart';
import '../services/app_controller.dart';
import '../services/settings.dart';
import 'app_scope.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'thinking_icon.dart';
import 'update_widgets.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _keys = {for (final s in SettingsSection.values) s: GlobalKey()};
  AppController? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = ArceScope.of(context);
    if (_app != app) {
      _app?.settingsSection.removeListener(_jump);
      _app = app..settingsSection.addListener(_jump);
      WidgetsBinding.instance.addPostFrameCallback((_) => _jump());
    }
  }

  @override
  void dispose() {
    _app?.settingsSection.removeListener(_jump);
    super.dispose();
  }

  void _jump() {
    final section = _app?.settingsSection.value;
    final context = section == null ? null : _keys[section]?.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    _app!.settingsSection.value = null;
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const PageHeading('詳細設定', '基本設定はチャットからすばやく変更できます。'),
              KeyedSubtree(key: _keys[SettingsSection.basic], child: const SectionTitle('基本設定')),
              ArceCard(
                child: Column(children: [
                  SettingRow(
                    icon: ArceSvg.brainOutline,
                    title: 'Thinking 表示',
                    subtitle: '生成中の状態と思考プロセスを表示します',
                    trailing: ArceSwitch(value: s.thinking, onChanged: (v) => set((x) => x.copyWith(thinking: v))),
                  ),
                  SettingRow(
                    icon: ArceSvg.searchClock,
                    title: 'Search',
                    subtitle: 'AIが必要と判断したときにWeb検索を使います',
                    trailing: ArceSwitch(value: s.searchEnabled, onChanged: (v) => set((x) => x.copyWith(searchEnabled: v))),
                  ),
                  SettingRow(
                    icon: ArceSvg.bolt,
                    title: 'HyperLoad',
                    subtitle: 'CPUを使い切って高速化します（発熱・消費電力が増えます）',
                    trailing: ArceSwitch(value: s.hyperLoad, onChanged: (v) => set((x) => x.copyWith(hyperLoad: v))),
                  ),
                  SettingRow(
                    icon: ArceSvg.clockCircle,
                    title: 'Thinking アイコン',
                    subtitle: '生成中に使う表示スタイル',
                    last: true,
                    trailing: const SizedBox.shrink(),
                  ),
                  _StyleOptions(current: s.thinkingStyle, onPick: (v) {
                    set((x) => x.copyWith(thinkingStyle: v));
                    app.showToast('Thinkingアイコンを変更しました');
                  }),
                ]),
              ),
              KeyedSubtree(key: _keys[SettingsSection.answer], child: const SectionTitle('回答')),
              ArceCard(
                child: Column(children: [
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
                    trailing: _Cycle<int>(
                      value: s.maxChars,
                      values: const [0, 300, 800, 1500, 3000],
                      label: (v) => v == 0 ? '制限なし' : '$v',
                      onChanged: (v) => set((x) => x.copyWith(maxChars: v)),
                    ),
                  ),
                  SettingRow(
                    icon: ArceSvg.grid,
                    title: '比較する候補数',
                    subtitle: '返信の「候補」から同じ質問への回答を作り、選んだものだけ履歴に残します',
                    trailing: _Cycle<int>(
                      value: s.candidateCount,
                      values: const [2, 3, 4],
                      label: (v) => '$v 件',
                      onChanged: (v) => set((x) => x.copyWith(candidateCount: v)),
                    ),
                  ),
                  _TextRow(
                    icon: ArceSvg.globe,
                    title: 'SearXNG のアドレス',
                    subtitle: '自分の検索サーバー（空欄なら DuckDuckGo のみ）',
                    value: s.searxngUrl,
                    hint: 'http://192.168.0.10:8080',
                    last: true,
                    onChanged: (v) => set((x) => x.copyWith(searxngUrl: v)),
                  ),
                ]),
              ),
              KeyedSubtree(key: _keys[SettingsSection.display], child: const SectionTitle('表示・プライバシー')),
              ArceCard(
                child: Column(children: [
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
                    icon: ArceSvg.shieldMinus,
                    title: '端末内保存',
                    subtitle: '会話とモデルはこの端末内にだけ保存されます',
                    last: true,
                    trailing: StatusLabel('有効', color: context.c.green, background: context.c.greenSoft),
                  ),
                ]),
              ),
              KeyedSubtree(key: _keys[SettingsSection.developer], child: const SectionTitle('開発者設定（次にモデルを読み込むときに反映）')),
              ArceCard(
                child: Column(children: [
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
                    subtitle: 'Q8 にするとメモリが約半分になります',
                    trailing: _Cycle<KvCacheType>(
                      value: s.kvCache,
                      values: KvCacheType.values,
                      label: (v) => v == KvCacheType.f16 ? 'F16' : 'Q8_0',
                      onChanged: (v) => set((x) => x.copyWith(kvCache: v)),
                    ),
                  ),
                  SettingRow(
                    icon: ArceSvg.file,
                    title: '最大トークン数',
                    subtitle: '1回の返信の長さの目安',
                    trailing: _Cycle<int>(
                      value: s.maxTokens,
                      values: const [1024, 2048, 4096, 8192],
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
                    subtitle: '1回の返信の中で使えるツールの回数',
                    trailing: _Cycle<int>(
                      value: s.maxToolRounds,
                      values: const [2, 4, 6, 8],
                      label: (v) => '$v',
                      onChanged: (v) => set((x) => x.copyWith(maxToolRounds: v)),
                    ),
                  ),
                  SettingRow(
                    icon: ArceSvg.alert,
                    title: 'Force Execution',
                    subtitle: 'メモリ不足の警告があっても、モデルの選択を許可します',
                    last: true,
                    trailing: ArceSwitch(value: s.forceExecution, onChanged: (v) => set((x) => x.copyWith(forceExecution: v))),
                  ),
                ]),
              ),
              KeyedSubtree(key: _keys[SettingsSection.update], child: const SectionTitle('アップデート')),
              ArceCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                ]),
              ),
              _Footer(app: app),
            ]),
          ),
        );
      },
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
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('ARCE.AI · ローカルAI', style: ts(context, 9, color: c.muted)),
        ListenableBuilder(
          listenable: app.updates,
          builder: (context, _) => Text('v${app.updates.currentVersion ?? '—'}', style: ts(context, 9, weight: FontWeight.w600)),
        ),
      ]),
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
      child: Wrap(spacing: 7, runSpacing: 7, children: [
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
                  child: Column(children: [
                    SizedBox(height: 30, child: Center(child: ThinkingIcon(style: style, size: 25))),
                    const SizedBox(height: 5),
                    Text(
                      _names[style]!,
                      style: ts(context, 9, color: style == current ? c.accent : c.muted, weight: style == current ? FontWeight.w700 : FontWeight.w500),
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Tapping steps to the next value, like the pill buttons of the original interface.
class _Cycle<T> extends StatelessWidget {
  const _Cycle({required this.value, required this.values, required this.label, required this.onChanged});
  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final i = values.indexOf(value);
    return ValuePill(label(value), onTap: () => onChanged(values[(i + 1) % values.length]));
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({required this.value, required this.items, required this.onChanged});
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.line)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: items.containsKey(value) ? value : items.keys.first,
          isDense: true,
          dropdownColor: c.surface,
          icon: ArceIcon(ArceSvg.chevronDown, size: 14, color: c.muted),
          style: ts(context, 10, weight: FontWeight.w600),
          items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.icon, required this.title, required this.subtitle, required this.value, required this.onChanged});
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
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
      child: Column(children: [
        Row(children: [
          Container(
            width: 31,
            height: 31,
            decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(10)),
            alignment: Alignment.center,
            child: ArceIcon(icon, size: 16, color: c.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: ts(context, 11, weight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(subtitle, style: ts(context, 9, color: c.muted, height: 1.45)),
            ]),
          ),
          Text('${(value * 100).round()}%', style: ts(context, 10, weight: FontWeight.w600)),
        ]),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(trackHeight: 3, overlayShape: SliderComponentShape.noOverlay),
          child: Slider(value: value, onChanged: onChanged, divisions: 20),
        ),
      ]),
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
  });

  final String icon;
  final String title;
  final String subtitle;
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;
  final bool obscure;
  final bool last;

  @override
  State<_TextRow> createState() => _TextRowState();
}

class _TextRowState extends State<_TextRow> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);

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
      decoration: BoxDecoration(border: widget.last ? null : Border(bottom: BorderSide(color: c.line))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 31,
            height: 31,
            decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(10)),
            alignment: Alignment.center,
            child: ArceIcon(widget.icon, size: 16, color: c.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.title, style: ts(context, 11, weight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(widget.subtitle, style: ts(context, 9, color: c.muted, height: 1.45)),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          obscureText: widget.obscure,
          style: ts(context, 11.5),
          onChanged: widget.onChanged,
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.hint,
            hintStyle: ts(context, 11.5, color: c.faint),
            filled: true,
            fillColor: c.surface2,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: BorderSide(color: c.line)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: BorderSide(color: c.line)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: BorderSide(color: c.accent)),
          ),
        ),
      ]),
    );
  }
}
