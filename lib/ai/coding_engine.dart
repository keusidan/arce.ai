import 'dart:async';

import '../core/agents.dart';
import '../core/coding_plan.dart';
import '../core/engine.dart';
import '../core/generation.dart';
import 'chatml_bridge.dart';
import 'model_hints.dart';
import 'provider.dart';

/// One model that can be given a job: an online provider's model, or the model on the device.
abstract interface class RoleModel {
  /// What the reply says about who did the work.
  String get label;

  /// How many requests may run at once. The device model runs one; an online one several.
  int get maxParallel;

  /// Sends [messages] and returns the whole answer. [cancelled] is checked while it streams.
  /// [maxTokens] 0 means "decide": the model's own setting, the maker's recommendation, then
  /// [autoTokens].
  Future<String> ask(
    List<AiMessage> messages, {
    required int maxTokens,
    required bool Function() cancelled,
    double temperature = 0.3,
    int autoTokens = 4096,
  });

  /// Stops whatever is running on this model.
  void cancel();
}

/// An online model, asked through its provider.
class ProviderRole implements RoleModel {
  ProviderRole(this.provider, {this.maxParallel = 4});

  final AiProvider provider;

  @override
  final int maxParallel;

  @override
  String get label => '${provider.label} · ${provider.modelId}';

  @override
  Future<String> ask(
    List<AiMessage> messages, {
    required int maxTokens,
    required bool Function() cancelled,
    double temperature = 0.3,
    int autoTokens = 4096,
  }) async {
    final out = StringBuffer();
    final model = provider.modelConfig;
    final hint = ModelHints.of(provider.modelId);
    final request = AiRequest(
      messages: messages,
      model: provider.modelId,
      // a number typed in the coding settings is the user's; 0 leaves it to the model
      maxTokens: ModelHints.resolveMaxTokens(
        modelSetting: maxTokens > 0 ? maxTokens : model?.intParam('maxTokens'),
        requestedIsUserSet: false,
        requested: autoTokens,
        hint: hint,
        maxOutput: model?.maxOutputTokens,
        context: model?.contextTokens,
        promptTokens: ModelHints.estimateTokens([for (final m in messages) m.text].join('\n')),
      ),
      // the maker's recommended sampling replaces the role's own (a reasoning model does not
      // want the low temperature that suits a plain one)
      temperature: model?.param('temperature') ?? hint?.temperature ?? temperature,
      topP: model?.param('topP') ?? hint?.topP ?? 0.95,
    );
    try {
      await for (final delta in provider.stream(request).takeWhile((_) => !cancelled())) {
        if (delta is TextDelta) out.write(delta.text);
      }
    } on AiProviderException catch (e) {
      throw EngineException(e.message);
    }
    return out.toString();
  }

  /// The request is dropped when [ask] sees `cancelled()`; there is nothing else to stop.
  @override
  void cancel() {}
}

/// The model on the device. One request at a time, and it answers without a thinking block.
class LocalRole implements RoleModel {
  LocalRole(this.engine, {this.name = '端末のモデル'});

  final InferenceEngine engine;
  final String name;

  @override
  int get maxParallel => 1;

  @override
  String get label => name;

  @override
  Future<String> ask(
    List<AiMessage> messages, {
    required int maxTokens,
    required bool Function() cancelled,
    double temperature = 0.3,
    int autoTokens = 4096,
  }) async {
    final out = StringBuffer();
    final request = GenerateRequest(
      prompt: chatMl(messages),
      toolCallSchema: null,
      thinking: false,
      maxTokens: maxTokens > 0 ? maxTokens : autoTokens,
      sampling: SamplingParams(temperature: temperature, topP: 0.8, topK: 20, minP: 0),
    );
    await for (final event in engine.generate(request)) {
      if (cancelled()) break;
      if (event is Piece) out.write(event.text);
    }
    return out.toString();
  }

  @override
  void cancel() => engine.cancel();

  /// The ChatML prompt of [messages], ending where the model starts its answer (with the thinking
  /// block already closed, as the chat does when thinking is off).
  static String chatMl(List<AiMessage> messages) {
    final b = StringBuffer();
    for (final m in messages) {
      final role = switch (m.role) {
        AiRole.system => 'system',
        AiRole.assistant => 'assistant',
        _ => 'user',
      };
      b.write('<|im_start|>$role\n${m.text}<|im_end|>\n');
    }
    b.write('<|im_start|>assistant\n<think>\n\n</think>\n\n');
    return b.toString();
  }
}

/// Lets only [n] jobs run at once; the others wait their turn.
class _Gate {
  _Gate(this.n);
  final int n;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() job) async {
    if (_running >= n) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await job();
    } finally {
      if (_waiting.isEmpty) {
        _running--;
      } else {
        _waiting.removeAt(0).complete();
      }
    }
  }
}

/// The coding mode: a design model splits the request into tasks, developer requests write them
/// at the same time, and the design model reads the result and sends back what is wrong.
///
/// The expensive model only writes a short plan and a short verdict; the long code comes from the
/// cheaper one. It looks like one more inference engine, so the chat, the history and the stop
/// button need no change.
class CodingEngine implements InferenceEngine {
  CodingEngine({required this.settings, required this.roleFor});

  final CodingSettings Function() settings;

  /// The model behind a `provider|model` reference, or null when it cannot be used now (the
  /// provider was removed, the device model is not loaded).
  final RoleModel? Function(String ref) roleFor;

  /// The agent the coding mode is for.
  static String get agentId => Agents.coding.id;

  bool _cancelled = false;
  final _active = <RoleModel>{};

  /// True when this request should be split between the two models: the mode is on, both roles
  /// have a usable model, and it is the coding agent writing a fresh answer (not continuing one).
  bool handles(GenerateRequest request) {
    final s = settings();
    return s.isReady &&
        request.agentId == agentId &&
        !request.continuation &&
        roleFor(s.planner) != null &&
        roleFor(s.developer) != null;
  }

  @override
  bool get isLoaded => true;

  @override
  Future<void> load(LoadParams params) async {}

  @override
  Future<void> unload() async {}

  @override
  void cancel() {
    _cancelled = true;
    for (final role in _active) {
      role.cancel();
    }
  }

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) {
    final controller = StreamController<GenerationEvent>();
    // the viewer stopped listening (the chat's stop button)
    controller.onCancel = cancel;
    unawaited(_work(request, controller));
    return controller.stream;
  }

  Future<void> _work(GenerateRequest request, StreamController<GenerationEvent> out) async {
    _cancelled = false;
    _active.clear();
    void say(String text) {
      if (!out.isClosed) out.add(Piece(text));
    }

    try {
      final s = settings();
      final planner = roleFor(s.planner);
      final developer = roleFor(s.developer);
      if (planner == null || developer == null) {
        throw EngineException('設計モデルか開発モデルが使えません。設定の「コーディングモード」を確認してください');
      }
      _active
        ..add(planner)
        ..add(developer);

      final conversation = [
        for (final m in ChatMlBridge.messages(request.prompt))
          if (m.role == AiRole.user || m.role == AiRole.assistant) m,
      ];
      final lastUser = conversation.lastWhere(
        (m) => m.role == AiRole.user,
        orElse: () => const AiMessage(AiRole.user),
      );
      if (lastUser.text.trim().isEmpty) throw EngineException('送信する内容を組み立てられませんでした');
      bool cancelled() => _cancelled;

      // 1. the design model plans
      final planText = await planner.ask(
        [AiMessage(AiRole.system, text: CodingPrompts.planner(s.maxTasks)), ...conversation],
        maxTokens: s.plannerMaxTokens,
        autoTokens: 8192,
        cancelled: cancelled,
      );
      if (_cancelled) return _finish(out, FinishReason.cancelled);

      final plan = CodingPrompts.parsePlan(planText, maxTasks: s.maxTasks);
      if (plan == null) {
        // no plan: a question, or a job too small to split. The design model's answer stands.
        say(planText.trim());
        return _finish(out, FinishReason.eog);
      }

      final gate = _Gate(developer.maxParallel < 1 ? 1 : (s.parallel < developer.maxParallel ? s.parallel : developer.maxParallel));
      say('**設計**（${planner.label}）\n${plan.summary.isEmpty ? '' : '${plan.summary}\n'}\n');
      say('**タスク**（${plan.tasks.length}件）\n');
      for (var i = 0; i < plan.tasks.length; i++) {
        say('${i + 1}. ${plan.tasks[i].title}\n');
      }
      say('\n> 開発: ${developer.label}'
          '${plan.tasks.length > 1 ? '（最大${gate.n}件を同時に）' : ''}\n');

      // 2. the developers write, all at once
      final results = <String, String>{};
      Future<void> develop(CodingTask task, {String? previous, String? feedback}) => gate.run(() async {
        if (_cancelled) return;
        final messages = [
          const AiMessage(AiRole.system, text: CodingPrompts.developer),
          AiMessage(AiRole.user, text: CodingPrompts.developerTask(lastUser.text, plan, task)),
          if (previous != null) AiMessage(AiRole.assistant, text: previous),
          if (feedback != null)
            AiMessage(
              AiRole.user,
              text: 'Reviewer feedback:\n$feedback\n\nFix it and output the complete corrected files.',
            ),
        ];
        try {
          results[task.id] = (await developer.ask(
            messages,
            maxTokens: s.developerMaxTokens,
            autoTokens: 16384,
            cancelled: cancelled,
            temperature: 0.2,
          )).trim();
        } on EngineException catch (e) {
          results[task.id] = '（このタスクは失敗しました: ${e.message}）';
        } catch (e) {
          results[task.id] = '（このタスクは失敗しました: $e）';
        }
      });
      await Future.wait([for (final task in plan.tasks) develop(task)]);
      if (_cancelled) return _finish(out, FinishReason.cancelled);

      // 3. the design model reads the result and may send work back
      final notes = <String>[];
      for (var round = 1; round <= s.reviewRounds; round++) {
        final verdict = CodingPrompts.parseReview(
          await planner.ask(
            [
              AiMessage(AiRole.system, text: CodingPrompts.reviewer(plan.tasks.length)),
              AiMessage(AiRole.user, text: CodingPrompts.reviewInput(lastUser.text, plan, results)),
            ],
            maxTokens: s.plannerMaxTokens,
            autoTokens: 8192,
            cancelled: cancelled,
          ),
          taskIds: {for (final t in plan.tasks) t.id},
        );
        if (_cancelled) return _finish(out, FinishReason.cancelled);
        if (verdict.notes.isNotEmpty) notes.add(verdict.notes);
        if (verdict.approved) {
          say('> レビュー: 承認\n');
          break;
        }
        say('> レビュー$round: ${verdict.fixes.length}件の修正を指示（${verdict.fixes.keys.join('、')}）\n');
        await Future.wait([
          for (final task in plan.tasks)
            if (verdict.fixes.containsKey(task.id))
              develop(task, previous: results[task.id], feedback: verdict.fixes[task.id]),
        ]);
        if (_cancelled) return _finish(out, FinishReason.cancelled);
      }

      // 4. the result, in the order of the plan
      say('\n---\n');
      for (var i = 0; i < plan.tasks.length; i++) {
        final task = plan.tasks[i];
        say('\n### ${i + 1}. ${task.title}\n\n${results[task.id] ?? '（結果がありません）'}\n');
      }
      if (notes.isNotEmpty) say('\n**レビューのメモ**: ${notes.join(' / ')}\n');
      _finish(out, FinishReason.eog);
    } on EngineException catch (e) {
      _fail(out, e);
    } catch (e) {
      _fail(out, EngineException('コーディングモードの途中で失敗しました（$e）'));
    }
  }

  void _finish(StreamController<GenerationEvent> out, FinishReason reason) {
    if (out.isClosed) return;
    out
      ..add(Finished(reason))
      ..close();
  }

  void _fail(StreamController<GenerationEvent> out, Object error) {
    if (out.isClosed) return;
    out
      ..addError(error)
      ..close();
  }
}
