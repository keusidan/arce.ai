import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/artifacts.dart';
import '../core/chat_controller.dart';
import '../core/generation.dart';
import '../core/markdown_lite.dart';
import '../core/protocol.dart';
import '../core/tool_runtime.dart';
import '../services/app_controller.dart';
import '../services/settings.dart';
import 'arce_text_field.dart';
import 'app_scope.dart';
import 'svg_icons.dart';
import 'theme.dart';
import 'thinking_icon.dart';
import 'widgets.dart';

Future<void> copyToClipboard(BuildContext context, String text) async {
  final app = ArceScope.maybeOf(context);
  await Clipboard.setData(ClipboardData(text: text));
  app?.showToast('コピーしました');
}

Future<void> openUrl(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

/// Opens an HTML artifact in the system browser through the local preview server.
Future<void> previewHtml(BuildContext context, String html) async {
  final app = ArceScope.of(context);
  try {
    final uri = await app.preview.publish(html);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    app.showToast('プレビューを開けませんでした');
  }
}

class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.message, required this.isLast, required this.state});

  final UiMessage message;
  final bool isLast;
  final ChatState state;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final user = message.role == Role.user;
    final time = message.time == null ? '' : formatTime(message.time!);
    final width = MediaQuery.sizeOf(context).width;
    final maxWidth = (width * .88).clamp(0.0, 720.0);

    if (user) {
      return Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text(time, style: ts(context, 10, color: c.muted)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                decoration: BoxDecoration(
                  color: c.userBubble,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(15),
                    topRight: Radius.circular(4),
                    bottomLeft: Radius.circular(15),
                    bottomRight: Radius.circular(15),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message.text, style: ts(context, 13, height: 1.72)),
                    if (message.attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final name in message.attachments) FileChip(name: name),
                        ]),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // The reply is plain text over the whole width, like a document: no avatar, no name or role above
    // it and no bubble. Only what the user says sits in a bubble.
    final generating = isLast && state.isGenerating;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.thinking.trim().isNotEmpty) ThinkingBlock(
            text: message.thinking,
            live: generating && message.thinkingSince > 0,
            expanded: ArceScope.maybeOf(context)?.settings.value.thinkingExpanded ?? true,
            thinkingMs: message.thinkingMs,
            thinkingSince: message.thinkingSince,
          ),
        for (final activity in message.activities) ActivityView(activity: activity),
        if (message.text.trim().isNotEmpty || message.finish == FinishReason.error)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: SizedBox(width: double.infinity, child: RichReply(text: message.text)),
          ),
        if (!generating && message.text.isNotEmpty) MessageActions(message: message, isLast: isLast, state: state),
      ],
    );
  }
}

/// A reply written in Markdown: headings, bold / italic / strike / `code`, links, lists, quotes,
/// rules, tables and code blocks (see [MarkdownLite] for what is read).
class RichReply extends StatelessWidget {
  const RichReply({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => MarkdownBlocks(blocks: MarkdownLite.parse(text));
}

/// Blocks one under another. A heading has more room above it than the other blocks.
class MarkdownBlocks extends StatelessWidget {
  const MarkdownBlocks({super.key, required this.blocks});
  final List<Block> blocks;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : (blocks[i] is Heading ? 14 : 8)),
            child: _block(context, blocks[i]),
          ),
      ],
    );
  }

  static const _headingSizes = [18.0, 16.0, 14.5, 13.5, 13.0, 13.0];

  Widget _block(BuildContext context, Block block) {
    final c = context.c;
    return switch (block) {
      Paragraph(:final spans) => InlineText(spans: spans, size: 13, height: 1.72),
      Heading(:final level, :final spans) => InlineText(spans: spans, size: _headingSizes[level - 1], height: 1.5, weight: FontWeight.w700),
      Rule() => Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: c.line),
      CodeBlock() => CodeCard(block: block),
      ListBlock(:final items) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final item in items) _listItem(context, item)]),
      Quote(:final blocks, :final raw) => Container(
          width: double.infinity,
          padding: const EdgeInsets.only(left: 11),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: c.line, width: 3))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // a long quote is usually a prompt to hand to another AI: it can be copied as it is
            if (_isLongQuote(raw)) Align(alignment: Alignment.centerRight, child: _MiniAction(label: 'コピー', svg: ArceSvg.copy, onTap: () => copyToClipboard(context, raw))),
            MarkdownBlocks(blocks: blocks),
          ]),
        ),
      TableBlock() => _table(context, block),
    };
  }

  /// Whether a quote gets a copy button: a few lines, or a long line.
  static bool _isLongQuote(String raw) => raw.length >= 80 || '\n'.allMatches(raw).length >= 2;

  Widget _listItem(BuildContext context, ListItem item) {
    final c = context.c;
    final marker = item.checked != null
        ? Icon(item.checked! ? Icons.check_box : Icons.check_box_outline_blank, size: 16, color: item.checked! ? c.accent : c.muted)
        : Text(
            item.number != null ? '${item.number}.' : const ['•', '◦', '▪'][item.depth.clamp(0, 2)],
            style: ts(context, 13, height: 1.72, color: c.muted),
          );
    return Padding(
      padding: EdgeInsets.only(left: item.depth * 18.0, top: 2, bottom: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 24,
          child: Padding(
            padding: EdgeInsets.only(top: item.checked != null ? 4 : 0, right: 6),
            child: Align(alignment: Alignment.topRight, child: marker),
          ),
        ),
        Expanded(child: InlineText(spans: item.spans, size: 13, height: 1.65)),
      ]),
    );
  }

  /// A table scrolls sideways when it is wider than the screen; one cell is at most 280 wide.
  Widget _table(BuildContext context, TableBlock table) {
    final c = context.c;
    Widget cell(List<Span> spans, int column, {bool header = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: InlineText(
              spans: spans,
              size: 12,
              height: 1.5,
              weight: header ? FontWeight.w700 : FontWeight.w400,
              align: switch (table.aligns[column]) {
                ColumnAlign.left => TextAlign.left,
                ColumnAlign.center => TextAlign.center,
                ColumnAlign.right => TextAlign.right,
              },
            ),
          ),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: c.line),
          children: [
            TableRow(
              decoration: BoxDecoration(color: c.surface2),
              children: [for (var col = 0; col < table.header.length; col++) cell(table.header[col], col, header: true)],
            ),
            for (final row in table.rows) TableRow(children: [for (var col = 0; col < row.length; col++) cell(row[col], col)]),
          ],
        ),
      ),
    );
  }
}

/// Styled text of [Span]s; a link opens in the browser when tapped.
class InlineText extends StatefulWidget {
  const InlineText({super.key, required this.spans, required this.size, this.height, this.weight = FontWeight.w400, this.align});

  final List<Span> spans;
  final double size;
  final double? height;
  final FontWeight weight;
  final TextAlign? align;

  @override
  State<InlineText> createState() => _InlineTextState();
}

class _InlineTextState extends State<InlineText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _release() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    _release();
    final base = ts(context, widget.size, height: widget.height, weight: widget.weight);
    TextSpan piece(Span s) {
      var style = base;
      if (s.bold) style = style.copyWith(fontWeight: FontWeight.w700);
      if (s.italic) style = style.copyWith(fontStyle: FontStyle.italic);
      if (s.strike) style = style.copyWith(decoration: TextDecoration.lineThrough);
      if (s.code) {
        style = style.copyWith(fontFamily: 'monospace', fontSize: widget.size - 1, backgroundColor: c.surface3.withValues(alpha: .7));
      }
      GestureRecognizer? tap;
      if (s.link != null) {
        final url = s.link!;
        final recognizer = TapGestureRecognizer()..onTap = () => openUrl(url);
        _recognizers.add(recognizer);
        tap = recognizer;
        style = style.copyWith(
          color: c.accent,
          decoration: s.strike ? TextDecoration.combine([TextDecoration.underline, TextDecoration.lineThrough]) : TextDecoration.underline,
          decorationColor: c.accent,
        );
      }
      return TextSpan(text: s.text, style: style, recognizer: tap);
    }

    return Text.rich(TextSpan(children: [for (final s in widget.spans) piece(s)]), style: base, textAlign: widget.align);
  }
}

/// A code block: copy, preview (HTML), and fold. A long block is folded from the start when the
/// setting 長いコードブロックを折りたたむ行数 says so; a block that is still being written is open.
class CodeCard extends StatefulWidget {
  const CodeCard({super.key, required this.block});
  final CodeBlock block;

  @override
  State<CodeCard> createState() => _CodeCardState();
}

class _CodeCardState extends State<CodeCard> {
  bool? _open;

  int get _lines => '\n'.allMatches(widget.block.code).length + 1;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final block = widget.block;
    final foldFrom = ArceScope.maybeOf(context)?.settings.value.codeFoldLines ?? 0;
    final open = _open ?? (!block.closed || foldFrom <= 0 || _lines <= foldFrom);
    final isHtml = block.language.toLowerCase() == 'html';
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.line)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: c.surface3.withValues(alpha: .6),
            child: InkWell(
              onTap: () => setState(() => _open = !open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                child: Row(children: [
                  ArceIcon(open ? ArceSvg.chevronDown : ArceSvg.chevronRight, size: 13, color: c.muted),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${block.language.isEmpty ? 'code' : block.language}${open ? '' : '  ·  $_lines行'}',
                      style: ts(context, 10, color: c.muted, weight: FontWeight.w600),
                    ),
                  ),
                  if (!block.closed)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text('生成中…', style: ts(context, 10, color: c.muted)),
                    ),
                  if (isHtml && block.closed)
                    _MiniAction(label: 'プレビュー', svg: ArceSvg.eye, onTap: () => previewHtml(context, block.code)),
                  _MiniAction(label: 'コピー', svg: ArceSvg.copy, onTap: () => copyToClipboard(context, block.code)),
                ]),
              ),
            ),
          ),
          if (open) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(10),
              child: Text(
                block.code,
                style: ts(context, 12, height: 1.5, family: 'monospace', color: c.ink),
              ),
            ),
            // a long block has its buttons at the end too: the ones in the header are far away by then
            if (block.closed && _lines > 14)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  _MiniAction(label: '折りたたむ', svg: ArceSvg.chevronUp, onTap: () => setState(() => _open = false)),
                  _MiniAction(label: 'コピー', svg: ArceSvg.copy, onTap: () => copyToClipboard(context, block.code)),
                ]),
              ),
          ],
        ],
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({required this.label, required this.svg, required this.onTap});
  final String label;
  final String svg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            ArceIcon(svg, size: 12, color: context.c.muted),
            const SizedBox(width: 4),
            Text(label, style: ts(context, 10, color: context.c.muted)),
          ]),
        ),
      );
}

class MessageActions extends StatelessWidget {
  const MessageActions({super.key, required this.message, required this.isLast, required this.state});
  final UiMessage message;
  final bool isLast;
  final ChatState state;

  @override
  Widget build(BuildContext context) {
    final app = ArceScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(children: [
        _MiniAction(label: 'コピー', svg: ArceSvg.copy, onTap: () => copyToClipboard(context, message.text)),
        if (isLast && !state.isGenerating && message.question == null)
          _MiniAction(label: '再試行', svg: ArceSvg.retry, onTap: () => app.chat.regenerate()),
        if (isLast && state.canContinue)
          _MiniAction(label: '続行', svg: ArceSvg.chevronRight, onTap: () => app.chat.continueReply()),
      ]),
    );
  }
}

/// The model's reasoning, as the apps that run models on the device show it: a header that counts
/// the seconds while the model thinks ("考えています… 12秒") and says how long it thought afterwards
/// ("思考（12.3秒）"); under it the text itself, which streams in while the model thinks (in a box of
/// limited height that follows the newest line) and stays to be read afterwards. A tap on the header
/// folds and unfolds it. While the model thinks it is open; after that it follows the setting
/// 思考の内容を開いたまま表示, unless the reader has opened or folded it.
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({
    super.key,
    required this.text,
    required this.live,
    this.expanded = true,
    this.thinkingMs = 0,
    this.thinkingSince = 0,
  });

  final String text;
  final bool live;
  final bool expanded;

  /// How long the thinking that has ended took.
  final int thinkingMs;

  /// When the thinking that is going on began (epoch milliseconds); 0 when it is not going on.
  final int thinkingSince;

  /// "12秒", "1分05秒"; one decimal under ten seconds ("3.4秒").
  static String duration(int ms) {
    final seconds = ms / 1000;
    if (seconds < 10) return '${seconds.toStringAsFixed(1)}秒';
    final whole = seconds.round();
    if (whole < 60) return '$whole秒';
    return '${whole ~/ 60}分${(whole % 60).toString().padLeft(2, '0')}秒';
  }

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool? _open;
  Timer? _tick;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(ThinkingBlock old) {
    super.didUpdateWidget(old);
    _syncTimer();
    // while it thinks, the box follows the newest line (unless the reader scrolled up to read)
    if (widget.live && widget.text != old.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final position = _scroll.position;
        if (position.maxScrollExtent - position.pixels < 80) _scroll.jumpTo(position.maxScrollExtent);
      });
    }
  }

  void _syncTimer() {
    final running = widget.live && widget.thinkingSince > 0;
    if (running && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!running && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int get _elapsedMs {
    if (widget.live && widget.thinkingSince > 0) {
      return widget.thinkingMs + DateTime.now().millisecondsSinceEpoch - widget.thinkingSince;
    }
    return widget.thinkingMs;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final open = _open ?? (widget.live || widget.expanded);
    final text = widget.text.trim();
    final elapsed = _elapsedMs;
    final title = widget.live
        ? (elapsed >= 1000 ? '考えています… ${ThinkingBlock.duration(elapsed)}' : '考えています…')
        : (elapsed > 0 ? '思考（${ThinkingBlock.duration(elapsed)}）' : '思考プロセス');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _open = !open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(children: [
                ArceIcon(ArceSvg.brainLabel, size: 14, color: c.accent),
                const SizedBox(width: 6),
                Expanded(child: Text(title, style: ts(context, 11, weight: FontWeight.w600, color: c.muted))),
                Text('${text.length}文字', style: ts(context, 9.5, color: c.faint)),
                const SizedBox(width: 6),
                ArceIcon(open ? ArceSvg.chevronUp : ArceSvg.chevronDown, size: 15, color: c.muted),
              ]),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Container(
                padding: const EdgeInsets.only(left: 9),
                decoration: BoxDecoration(border: Border(left: BorderSide(color: c.line, width: 2))),
                // while it thinks the box is as high as it needs, up to a limit, and scrolls; afterwards
                // a long thought has a limit too, so it does not push the answer off the screen
                constraints: BoxConstraints(maxHeight: widget.live ? 190 : 340),
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: Text(text, style: ts(context, 11.5, color: c.muted, height: 1.65)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// What a tool did (search results, weather, time), with its sources as links.
class ActivityView extends StatefulWidget {
  const ActivityView({super.key, required this.activity});
  final ToolActivity activity;

  @override
  State<ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends State<ActivityView> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final a = widget.activity;
    final icon = switch (a.tool) {
      'Search' => ArceSvg.search,
      'Weather' => ArceSvg.sun,
      'Time' => ArceSvg.clock,
      _ => ArceSvg.bolt,
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: a.failed ? c.amberSoft : c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: a.failed ? Colors.transparent : c.line),
      ),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: a.links.isEmpty ? null : () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              ArceIcon(icon, size: 14, color: a.failed ? c.amber : c.accent),
              const SizedBox(width: 7),
              Expanded(child: Text(a.summary, style: ts(context, 11, color: a.failed ? c.amber : c.ink, height: 1.5))),
              if (a.links.isNotEmpty) ArceIcon(_open ? ArceSvg.chevronUp : ArceSvg.chevronDown, size: 15, color: c.muted),
            ]),
          ),
        ),
        if (_open)
          for (final link in a.links)
            InkWell(
              onTap: () => openUrl(link.url),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(31, 2, 10, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text.rich(TextSpan(children: [
                    TextSpan(
                      text: link.title,
                      style: ts(context, 11, color: c.accent, weight: FontWeight.w600),
                      recognizer: TapGestureRecognizer()..onTap = () => openUrl(link.url),
                    ),
                    TextSpan(text: '\n${link.url}', style: ts(context, 9.5, color: c.muted)),
                  ])),
                ),
              ),
            ),
      ]),
    );
  }
}

class FileChip extends StatelessWidget {
  const FileChip({super.key, required this.name, this.onRemove});
  final String name;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        ArceIcon(ArceSvg.file, size: 12, color: c.muted),
        const SizedBox(width: 5),
        Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: ts(context, 10, color: c.muted))),
        if (onRemove != null) ...[
          const SizedBox(width: 5),
          InkWell(onTap: onRemove, child: ArceIcon(ArceSvg.close, size: 12, color: c.muted)),
        ],
      ]),
    );
  }
}

/// The card shown while a reply is being produced: icon, current phase, and the steps so far.
class ThinkingCard extends StatefulWidget {
  const ThinkingCard({super.key, required this.task, required this.style});

  final TaskState task;
  final ThinkingStyle style;

  @override
  State<ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<ThinkingCard> {
  bool _closed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final searching = widget.task == TaskState.search;
    final title = switch (widget.task) {
      TaskState.search => '検索しています…',
      TaskState.thinking => '考えています…',
      _ => '回答を生成しています…',
    };
    // 0: preparing, 1: reasoning or searching, 2: writing the answer
    final active = widget.task == TaskState.generation ? 2 : 1;
    final steps = ['入力を受け付けました', searching ? '検索しています' : '内容を考えています', '回答を書いています'];
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 3, 0, 4),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: c.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ThinkingIcon(style: widget.style),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: ts(context, 13, weight: FontWeight.w700)),
            ]),
          ),
          IconTap(
            svg: _closed ? ArceSvg.chevronDown : ArceSvg.chevronUp,
            size: 17,
            onTap: () => setState(() => _closed = !_closed),
            tooltip: _closed ? '詳細を開く' : '詳細を折りたたむ',
          ),
        ]),
        if (!_closed)
          Padding(
            padding: const EdgeInsets.only(left: 42, top: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(children: [
                    ArceIcon(
                      i < active ? ArceSvg.check : ArceSvg.clock,
                      size: 12,
                      color: i < active ? c.green : (i == active ? c.accent : c.faint),
                    ),
                    const SizedBox(width: 8),
                    Text(steps[i], style: ts(context, 11, color: i == active ? c.ink : c.muted)),
                  ]),
                ),
            ]),
          ),
      ]),
    );
  }
}

/// An ask_user question: pick an option, several options, or type an answer.
class QuestionCard extends StatefulWidget {
  const QuestionCard({super.key, required this.tile, required this.onAnswer});

  final QuestionTile tile;
  final void Function(List<String> selected, String? freeText) onAnswer;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  final _picked = <String>{};
  final _free = TextEditingController();

  @override
  void dispose() {
    _free.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final tile = widget.tile;
    // a single choice with no free text answers on tap
    final instant = !tile.multiSelect && !tile.allowFreeInput;
    return Container(
      margin: const EdgeInsets.fromLTRB(39, 4, 0, 4),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.accent.withValues(alpha: .5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tile.title, style: ts(context, 13, weight: FontWeight.w700, height: 1.5)),
        const SizedBox(height: 10),
        Wrap(spacing: 7, runSpacing: 7, children: [
          for (final option in tile.options)
            _OptionChip(
              label: option,
              selected: _picked.contains(option),
              multi: tile.multiSelect,
              onTap: () {
                if (instant) {
                  widget.onAnswer([option], null);
                } else if (tile.multiSelect) {
                  setState(() => _picked.contains(option) ? _picked.remove(option) : _picked.add(option));
                } else {
                  setState(() => _picked..clear()..add(option));
                }
              },
            ),
        ]),
        if (tile.allowFreeInput) ...[
          const SizedBox(height: 10),
          ArceTextField(
            controller: _free,
            style: ts(context, 12),
            decoration: InputDecoration(
              isDense: true,
              hintText: '自由入力',
              hintStyle: ts(context, 12, color: c.faint),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.line)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.line)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.accent)),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
        if (!instant) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: PrimaryButton(label: '決定', onTap: (_picked.isEmpty && _free.text.trim().isEmpty) ? null : _submit),
          ),
        ],
      ]),
    );
  }

  void _submit() {
    if (_picked.isEmpty && _free.text.trim().isEmpty) return;
    widget.onAnswer(_picked.toList(), _free.text);
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({required this.label, required this.selected, required this.multi, required this.onTap});
  final String label;
  final bool selected;
  final bool multi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: selected ? c.accentSoft : c.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: selected ? c.accent : c.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          child: Text(
            multi ? '${selected ? '☑' : '☐'} $label' : label,
            style: ts(context, 12, color: selected ? c.accent : c.ink, weight: selected ? FontWeight.w700 : FontWeight.w500),
          ),
        ),
      ),
    );
  }
}

/// The chat's own place for "not working" messages.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key, required this.text, required this.tone, this.action});

  final String text;
  final BannerTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (bg, fg) = switch (tone) {
      BannerTone.warning => (c.amberSoft, c.amber),
      BannerTone.error => (c.red.withValues(alpha: .12), c.red),
      BannerTone.info => (c.accentSoft, c.accent),
    };
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(13)),
      child: Row(children: [
        ArceIcon(ArceSvg.alert, size: 18, color: fg),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: ts(context, 10.5, color: fg, height: 1.6))),
        ?action,
      ]),
    );
  }
}

enum BannerTone { warning, error, info }

/// The artifacts of one conversation, newest last (used by the chat tabs and Artifacts page).
List<ArtifactItem> artifactsOf(AppController app) => Artifacts.extract(app.chat.state.messages);
