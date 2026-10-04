import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'agents.dart';
import 'attachments.dart';
import 'engine.dart';
import 'generation.dart';
import 'prompt.dart';
import 'protocol.dart';
import 'stream_segmenter.dart';
import 'tool_runtime.dart';

enum Role { user, assistant }

class UiMessage {
  const UiMessage({
    required this.id,
    required this.role,
    required this.text,
    this.thinking = '',
    this.question,
    this.finish,
    this.activities = const [],
    this.agent,
    this.attachments = const [],
    this.time,
  });

  final int id;
  final Role role;
  final String text;
  final String thinking;
  final QuestionTile? question;
  final FinishReason? finish;
  final List<ToolActivity> activities;
  final String? agent;
  final List<String> attachments;
  final DateTime? time;

  UiMessage copyWith({
    String? text,
    String? thinking,
    QuestionTile? question,
    FinishReason? finish,
    List<ToolActivity>? activities,
  }) =>
      UiMessage(
        id: id,
        role: role,
        text: text ?? this.text,
        thinking: thinking ?? this.thinking,
        question: question ?? this.question,
        finish: finish ?? this.finish,
        activities: activities ?? this.activities,
        agent: agent,
        attachments: attachments,
        time: time,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'role': role.name,
        'text': text,
        'thinking': thinking,
        'question': question?.toJson(),
        'finish': finish?.name,
        'activities': [for (final a in activities) a.toJson()],
        'agent': agent,
        'attachments': attachments,
        'time': time?.millisecondsSinceEpoch,
      };

  factory UiMessage.fromJson(Map<String, Object?> json) => UiMessage(
        id: json['id'] as int,
        role: Role.values.byName(json['role'] as String),
        text: json['text'] as String,
        thinking: json['thinking'] as String? ?? '',
        question: json['question'] == null ? null : QuestionTile.fromJson((json['question'] as Map).cast()),
        finish: json['finish'] == null ? null : FinishReason.values.byName(json['finish'] as String),
        activities: [
          for (final a in (json['activities'] as List? ?? const [])) ToolActivity.fromJson((a as Map).cast()),
        ],
        agent: json['agent'] as String?,
        attachments: (json['attachments'] as List? ?? const []).cast<String>(),
        time: json['time'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['time'] as int),
      );
}

const _unset = Object();

class ChatState {
  const ChatState({
    this.messages = const [],
    this.task = TaskState.waiting,
    this.thinkingEnabled = true,
    this.error,
    this.notice,
  });

  final List<UiMessage> messages;
  final TaskState task;
  final bool thinkingEnabled;
  final String? error;

  /// e.g. the selected agent expects a larger model than the one loaded (spec §17.2).
  final String? notice;

  bool get isGenerating =>
      task == TaskState.thinking || task == TaskState.generation || task == TaskState.search;

  QuestionTile? get pendingQuestion =>
      task == TaskState.userWait && messages.isNotEmpty ? messages.last.question : null;

  /// The last reply stopped before it was finished and can be continued (spec: 続行).
  bool get canContinue {
    if (isGenerating || messages.isEmpty) return false;
    final last = messages.last;
    return last.role == Role.assistant &&
        last.question == null &&
        (last.finish == FinishReason.length || last.finish == FinishReason.cancelled);
  }

  ChatState copyWith({
    List<UiMessage>? messages,
    TaskState? task,
    bool? thinkingEnabled,
    Object? error = _unset,
    Object? notice = _unset,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        task: task ?? this.task,
        thinkingEnabled: thinkingEnabled ?? this.thinkingEnabled,
        error: identical(error, _unset) ? this.error : error as String?,
        notice: identical(notice, _unset) ? this.notice : notice as String?,
      );
}

/// The settings that shape one generation; read afresh for every request.
class GenerationSettings {
  const GenerationSettings({
    this.tone,
    this.maxChars = 0,
    this.maxTokens = 2048,
    this.searchEnabled = true,
    this.retryLimit = 2,
    this.maxToolRounds = 4,
    this.speedAccuracy = 0.5,
    this.modelParamsB,
    this.agentOverride,
    this.aiAgentSelection = false,
  });

  final String? tone;

  /// 0 = no limit. Asked of the model in the system prompt.
  final int maxChars;
  final int maxTokens;
  final bool searchEnabled;

  /// Regenerations allowed for a cut-off tool call (詳細設定「エラー再書き込み回数」).
  final int retryLimit;

  /// Tool calls allowed before one reply must finish; stops tool loops.
  final int maxToolRounds;

  /// 0 = fastest, 1 = most accurate (spec §8.1 速度 / 精度).
  final double speedAccuracy;

  /// Size of the loaded model in billions of parameters, when known.
  final double? modelParamsB;

  /// Agent chosen by the user; null lets the selector decide.
  final String? agentOverride;

  /// Let the loaded model settle the agent when the keyword rules are unsure (spec §17.1).
  final bool aiAgentSelection;

  /// The fast end of the slider skips reasoning and shortens replies; the accurate end keeps
  /// reasoning and allows longer replies. The user's own Thinking switch still wins when off.
  bool effectiveThinking(bool userSwitch) => userSwitch && speedAccuracy >= 0.25;

  int effectiveMaxTokens() {
    final n = (maxTokens * (0.5 + speedAccuracy)).toInt();
    return n < 256 ? 256 : n;
  }
}

/// Everything needed to restore a conversation, persisted by the app (spec §33/§34).
class ConversationSnapshot {
  const ConversationSnapshot({required this.messages, required this.history, required this.nextId});

  final List<UiMessage> messages;
  final List<ChatMessage> history;
  final int nextId;

  Map<String, Object?> toJson() => {
        'messages': [for (final m in messages) m.toJson()],
        'history': [for (final h in history) h.toJson()],
        'nextId': nextId,
      };

  factory ConversationSnapshot.fromJson(Map<String, Object?> json) => ConversationSnapshot(
        messages: [for (final m in (json['messages'] as List)) UiMessage.fromJson((m as Map).cast())],
        history: [for (final h in (json['history'] as List)) ChatMessage.fromJson((h as Map).cast())],
        nextId: json['nextId'] as int,
      );
}

/// Called at the points where a crash would lose work; [generating] marks an unfinished task.
typedef ConversationStore = void Function(ConversationSnapshot snapshot, {required bool generating});

class _Attempt {
  _Attempt(this.reason, this.thinking, this.answer, this.toolCallJson, this.cutInsideToolCall);
  final FinishReason reason;
  final String thinking;
  final String answer;
  final String? toolCallJson;
  final bool cutInsideToolCall;
}

/// Runs one conversation: picks an agent, builds prompts, streams output through
/// [StreamSegmenter], runs tool calls through [ToolRuntime] until the model answers, turns
/// ask_user into a question tile, and regenerates cut-off calls per [RetryPolicy].
class ChatController extends ChangeNotifier {
  ChatController(
    this._engine, {
    this._toolRuntime = const NoToolRuntime(),
    GenerationSettings Function()? settings,
    ConversationStore? store,
  })  : _settings = settings ?? (() => const GenerationSettings()),
        _store = store ?? ((_, {required generating}) {}) {
    _router = AgentRouter((prompt, schema) async {
      final out = StringBuffer();
      final stream = _engine
          .generate(GenerateRequest(
            prompt: prompt,
            toolCallSchema: null,
            thinking: false,
            maxTokens: 32,
            sampling: const SamplingParams(temperature: 0.1, topP: 1, topK: 1, minP: 0, dryMultiplier: 0),
            strictJsonSchema: schema,
          ))
          .where((e) => e is Piece)
          .cast<Piece>();
      final text = stream.fold<void>(null, (_, piece) => out.write(piece.text));
      try {
        await text.timeout(const Duration(seconds: 20));
      } on TimeoutException {
        _engine.cancel();
        return null;
      }
      return out.toString();
    });
  }

  final InferenceEngine _engine;
  final ToolRuntime _toolRuntime;
  final GenerationSettings Function() _settings;
  final ConversationStore _store;
  late final AgentRouter _router;

  ChatState _state = const ChatState();
  ChatState get state => _state;

  final List<ChatMessage> _history = [];
  int _nextId = 0;
  AgentDefinition? _agent;

  /// The request the agent is chosen for; selection runs lazily at the start of generation.
  (String, bool) _agentRequest = ('', false);
  bool _busy = false;

  void _update(ChatState Function(ChatState) change) {
    _state = change(_state);
    notifyListeners();
  }

  void setThinking(bool enabled) => _update((s) => s.copyWith(thinkingEnabled: enabled));

  ConversationSnapshot snapshot() =>
      ConversationSnapshot(messages: _state.messages, history: List.of(_history), nextId: _nextId);

  void restore(ConversationSnapshot snapshot) {
    _history
      ..clear()
      ..addAll(snapshot.history);
    _nextId = snapshot.nextId;
    // Choose the agent again for the restored conversation, from its last request.
    _agent = null;
    final lastUser = snapshot.messages.lastWhere(
      (m) => m.role == Role.user,
      orElse: () => const UiMessage(id: -1, role: Role.user, text: ''),
    );
    _agentRequest = (lastUser.text, false);
    final waiting = snapshot.messages.isNotEmpty && snapshot.messages.last.question != null;
    _update((s) => ChatState(
          messages: snapshot.messages,
          task: waiting ? TaskState.userWait : TaskState.waiting,
          thinkingEnabled: s.thinkingEnabled,
        ));
  }

  void clear() => restore(const ConversationSnapshot(messages: [], history: [], nextId: 0));

  /// Returns when the reply has finished (or stopped for a question); callers may ignore it.
  Future<void> send(String text, {List<Attachment> attachments = const []}) {
    if ((text.trim().isEmpty && attachments.isEmpty) || _state.isGenerating || _busy) return Future.value();
    _history.add(UserTurn(AttachmentPolicy.compose(text, attachments)));
    _append(UiMessage(
      id: _nextId++,
      role: Role.user,
      text: text,
      attachments: [for (final a in attachments) a.name],
      time: DateTime.now(),
    ));
    _agent = null;
    _agentRequest = (text, attachments.isNotEmpty);
    return _start('');
  }

  /// Answers the pending question tile and resumes generation.
  Future<void> answer(List<String> selected, String? freeText) {
    if (_state.pendingQuestion == null || _busy) return Future.value();
    final free = freeText != null && freeText.trim().isNotEmpty ? [freeText] : const <String>[];
    final answer = [...selected, ...free].join(', ');
    _history.add(ToolResponseTurn(answer));
    _append(UiMessage(id: _nextId++, role: Role.user, text: answer, time: DateTime.now()));
    return _start('');
  }

  void stop() => _engine.cancel();

  /// Replaces the last reply with a fresh one generated from the same context.
  Future<void> regenerate() {
    if (_state.isGenerating || _busy || _state.messages.isEmpty || _state.messages.last.role != Role.assistant) {
      return Future.value();
    }
    _dropLastReplyFromHistory();
    _update((s) => s.copyWith(messages: s.messages.sublist(0, s.messages.length - 1)));
    return _start('');
  }

  Future<void> continueReply() {
    if (!_state.canContinue || _busy) return Future.value();
    final partial = _state.messages.last;
    // The partial reply is regenerated from its own text, so drop it from the context first.
    if (_history.isNotEmpty && _history.last is AssistantTurn) _history.removeLast();
    _update((s) => s.copyWith(messages: s.messages.sublist(0, s.messages.length - 1)));
    return _start(partial.text);
  }

  /// Removes the assistant turns (and tool responses) since the last user or answer message.
  void _dropLastReplyFromHistory() {
    while (_history.isNotEmpty) {
      final last = _history.last;
      final before = _history.length >= 2 ? _history[_history.length - 2] : null;
      final isToolResult =
          last is ToolResponseTurn && before is AssistantTurn && before.toolCallJson != null;
      if (last is AssistantTurn || isToolResult) {
        _history.removeLast();
      } else {
        break;
      }
    }
  }

  Future<void> _start(String prefill) async {
    _busy = true;
    try {
      await _generate(prefill);
    } catch (e) {
      // anything unexpected must not leave the chat stuck in "generating"
      _fail(_nextId - 1, e.toString());
    } finally {
      _busy = false;
    }
  }

  Future<void> _generate(String prefill) async {
    final config = _settings();
    final agent = _agent ??= await _router.select(
      _agentRequest.$1,
      _agentRequest.$2,
      config.agentOverride,
      useModel: config.aiAgentSelection && _engine.isLoaded,
    );
    final tools = [for (final t in agent.tools) if (config.searchEnabled || t != Protocol.webSearch) t];
    final schema = tools.isEmpty ? null : jsonEncodeSchema(Protocol.toolCallSchema(tools));
    final retry = RetryPolicy(config.retryLimit);
    final instructions = [
      'Current role: ${agent.displayName}. ${agent.instructions}',
      if (config.maxChars > 0) 'Keep each reply under ${config.maxChars} characters.',
    ];
    final modelB = config.modelParamsB;
    final sizeNotice = modelB != null && modelB < agent.minModelParamsB
        ? '「${agent.displayName}」は${agent.minModelParamsB}B以上のモデルを推奨します（現在 ${modelB}B）。モデルは自動で変更しません。'
        : null;

    final id = _nextId++;
    _append(UiMessage(
      id: id,
      role: Role.assistant,
      text: prefill,
      agent: agent.displayName,
      time: DateTime.now(),
    ));
    _update((s) => s.copyWith(error: null, notice: sizeNotice));
    _store(snapshot(), generating: true);

    var earlierText = '';
    final activities = <ToolActivity>[];
    var rounds = 0;
    var roundPrefill = prefill;

    while (true) {
      final thinking = config.effectiveThinking(_state.thinkingEnabled) && roundPrefill.isEmpty;
      final prompt = ChatMlPromptBuilder.build(
        _history,
        tools,
        config.tone,
        thinking,
        assistantPrefill: roundPrefill,
        extraInstructions: instructions,
      );
      final request = GenerateRequest(
        prompt: prompt,
        toolCallSchema: schema,
        thinking: thinking,
        maxTokens: config.effectiveMaxTokens(),
        sampling: thinking ? SamplingParams.qwen3Thinking : SamplingParams.qwen3NonThinking,
      );

      var attempts = 0;
      late _Attempt result;
      while (true) {
        try {
          result = await _attempt(id, request, earlierText, roundPrefill);
        } on EngineException catch (e) {
          _fail(id, e.message);
          return;
        }
        final parsed = result.toolCallJson == null ? null : ToolCallParser.parse(result.toolCallJson!, tools);
        final semanticError = parsed is ParseInvalid ? parsed.reason : null;
        final step = retry.decide(
          result.reason,
          endedInsideToolCall: result.cutInsideToolCall,
          semanticError: semanticError,
          attemptsSoFar: attempts,
        );
        if (step is Regenerate) {
          attempts = step.attempt;
        } else if (step is Fail) {
          _fail(id, step.reason);
          return;
        } else {
          break;
        }
      }

      final parsed = result.toolCallJson == null ? null : ToolCallParser.parse(result.toolCallJson!, tools);
      final call = parsed is ParseOk ? parsed.call : null;
      _history.add(AssistantTurn(result.answer, call == null ? null : result.toolCallJson));
      final shown = _join(earlierText, result.answer);

      switch (call) {
        case null:
          _replace(id, (m) => m.copyWith(text: shown, finish: result.reason, activities: List.of(activities)));
          _finishWith(result.reason == FinishReason.cancelled ? TaskState.cancelled : TaskState.completed);
          return;
        case AskUser(:final tile):
          _replace(id, (m) => m.copyWith(text: shown, question: tile, finish: result.reason, activities: List.of(activities)));
          _finishWith(TaskState.userWait);
          return;
        default:
          rounds++;
          if (rounds > config.maxToolRounds) {
            _fail(id, 'tool calls exceeded ${config.maxToolRounds} rounds');
            return;
          }
          _update((s) => s.copyWith(task: call is WebSearch ? TaskState.search : TaskState.generation));
          final outcome = await _toolRuntime.run(call);
          activities.add(outcome.activity);
          _history.add(ToolResponseTurn(outcome.response));
          earlierText = shown;
          roundPrefill = '';
          _replace(id, (m) => m.copyWith(text: earlierText, activities: List.of(activities)));
      }
    }
  }

  /// One pass through the engine; streams text and thinking into message [id].
  Future<_Attempt> _attempt(int id, GenerateRequest request, String earlierText, String prefill) async {
    final task = GenerationTask();
    final segmenter = StreamSegmenter();
    var reason = FinishReason.error;
    var thinkingText = '';
    var answer = prefill;
    String? toolCallJson;

    void consume(List<StreamEvent> events) {
      for (final event in events) {
        switch (event) {
          case ThinkingText(:final text):
            thinkingText += text;
            task.moveTo(TaskState.thinking);
          case PlainText(:final text):
            answer += text;
            task.moveTo(TaskState.generation);
          case ToolCallEnd(:final json):
            toolCallJson = json;
          case ToolCallStart() || ToolCallDelta():
            task.moveTo(TaskState.generation);
        }
      }
      _replace(id, (m) => m.copyWith(text: _join(earlierText, answer), thinking: thinkingText));
      _update((s) => s.copyWith(task: task.state));
    }

    _update((s) => s.copyWith(task: request.thinking ? TaskState.thinking : TaskState.generation));
    await for (final event in _engine.generate(request)) {
      switch (event) {
        case Piece(:final text):
          consume(segmenter.feed(text));
        case Finished(reason: final r):
          reason = r;
      }
    }
    consume(segmenter.finish());
    return _Attempt(reason, thinkingText, answer, toolCallJson, segmenter.isInsideToolCall);
  }

  String _join(String earlier, String current) {
    if (earlier.trim().isEmpty) return current;
    if (current.trim().isEmpty) return earlier;
    return '$earlier\n\n$current';
  }

  void _finishWith(TaskState state) {
    _update((s) => s.copyWith(task: state));
    _store(snapshot(), generating: false);
  }

  void _fail(int id, String reason) {
    _replace(id, (m) => m.copyWith(finish: FinishReason.error));
    _update((s) => s.copyWith(task: TaskState.error, error: reason));
    _store(snapshot(), generating: false);
  }

  void _append(UiMessage message) => _update((s) => s.copyWith(messages: [...s.messages, message]));

  void _replace(int id, UiMessage Function(UiMessage) change) => _update(
        (s) => s.copyWith(messages: [for (final m in s.messages) m.id == id ? change(m) : m]),
      );
}

String jsonEncodeSchema(Map<String, Object?> schema) => jsonEncode(schema);
