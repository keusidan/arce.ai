import 'dart:async';

import '../core/coding_plan.dart';
import '../core/engine.dart';
import '../core/protocol.dart';
import '../core/run_progress.dart';
import '../core/tool_runtime.dart';
import 'provider.dart';
import 'roles.dart';

/// Carries out the `delegate` tool of the coding mode: the jobs the planner model wrote go to the
/// developer model, all at once (up to the limit), and what came back goes to the planner.
///
/// It decides nothing. How to split the work, whether the result is good and whether to send a job
/// back are the planner's calls; this class is the app's help with the calling: it holds the
/// developer model and its limits, runs the requests at the same time, remembers each result under
/// an id (so a job can be sent back with `revise`), and shows the user the files.
class DelegateRunner {
  DelegateRunner({required this.settings, required this.developer});

  final CodingSettings Function() settings;

  /// The developer model now, or null when it cannot be used (the provider was removed, the device
  /// model is not loaded).
  final RoleModel? Function() developer;

  static const _remembered = 200;

  final _results = <String, _Stored>{};
  var _count = 0;

  /// Runs [call]. [stop] completes when the user stops the reply. A job for the device model needs
  /// [acquireDevice] to succeed (one chat at a time) and gives it back through [releaseDevice].
  /// [meter] is told each request to the developer model and each job that ends, so the screen shows
  /// that the work goes on.
  Future<ToolOutcome> run(
    Delegate call, {
    required Future<void> stop,
    bool Function()? acquireDevice,
    void Function()? releaseDevice,
    RunMeter? meter,
  }) async {
    final s = settings();
    final model = developer();
    if (model == null) {
      return const ToolOutcome(
        'The developer model is not available now (its provider was removed or is incomplete, or the device model is not loaded). Do the work yourself.',
        ToolActivity('Delegate', '開発モデルが使えません', failed: true),
      );
    }
    final device = model.usesDevice;
    if (device && acquireDevice != null && !acquireDevice()) {
      return const ToolOutcome(
        'The device model is being used by another chat. Try again when it is done, or do the work yourself.',
        ToolActivity('Delegate', '端末のモデルを、ほかのチャットが使っています', failed: true),
        );
    }

    var stopped = false;
    unawaited(stop.then((_) {
      stopped = true;
      model.cancel();
    }));

    try {
      final limit = s.maxTasks.clamp(1, Protocol.maxDelegateTasks);
      final accepted = call.tasks.take(limit).toList();
      final refused = call.tasks.length - accepted.length;
      final gate = ConcurrencyGate(
        model.maxParallel < 1 ? 1 : (s.parallel < model.maxParallel ? s.parallel : model.maxParallel).clamp(1, 1 << 20),
      );
      final unknownRevise = <String>[];

      var ended = 0;
      final running = <String>[];
      void report() => meter?.stage(
        '開発モデルが作業しています（$ended/${accepted.length} 件完了）',
        detail: running.isEmpty ? '' : '作業中: ${running.join('、')}',
      );
      report();

      final jobs = <Future<_Stored>>[];
      for (final task in accepted) {
        final id = 'd${++_count}';
        final before = task.revise == null ? null : _results[task.revise];
        if (task.revise != null && before == null) unknownRevise.add(task.revise!);
        final base = before?.task ?? task;
        final summary = before?.summary ?? call.summary;
        final title = task.title.trim().isEmpty ? base.title : task.title;
        jobs.add(gate.run(() async {
          if (stopped) return _Stored(id, title, summary, base, '（停止しました）', failed: true);
          final messages = [
            const AiMessage(AiRole.system, text: CodingPrompts.developer),
            AiMessage(AiRole.user, text: CodingPrompts.developerTask(summary, base)),
            if (before != null) ...[
              AiMessage(AiRole.assistant, text: before.output),
              AiMessage(AiRole.user, text: CodingPrompts.correction(task.instructions)),
            ],
          ];
          running.add(title);
          meter?.developerRequest();
          report();
          try {
            final answer = await model.ask(
              messages,
              maxTokens: s.developerMaxTokens,
              autoTokens: 16384,
              cancelled: () => stopped,
              temperature: 0.2,
            );
            return _Stored(id, title, summary, base, answer.trim());
          } on Object catch (e) {
            final reason = e is EngineException ? e.message : '$e';
            return _Stored(id, title, summary, base, '（このタスクは失敗しました: $reason）', failed: true);
          } finally {
            running.remove(title);
            ended++;
            report();
          }
        }));
      }
      final done = await Future.wait(jobs);
      for (final result in done) {
        if (!result.failed) {
          _results[result.id] = result;
          while (_results.length > _remembered) {
            _results.remove(_results.keys.first);
          }
        }
      }

      final response = StringBuffer(stopped ? 'The user stopped the work. What was finished:\n' : 'Developer results (to correct one, call delegate with revise set to its id):\n');
      for (final r in done) {
        final shownToPlanner = s.resultChars > 0 && r.output.length > s.resultChars
            ? '${r.output.substring(0, s.resultChars)}\n[… ${r.output.length - s.resultChars} more characters, which the user can read …]'
            : r.output;
        response
          ..writeln()
          ..writeln('## ${r.id}: ${r.title}')
          ..writeln(shownToPlanner);
      }
      if (refused > 0) {
        response
          ..writeln()
          ..writeln('$refused task(s) were not run: at most $limit per call. Send them in another call.');
      }
      if (unknownRevise.isNotEmpty) {
        response
          ..writeln()
          ..writeln('No earlier result has the id ${unknownRevise.join(', ')}; the task was run as a new one.');
      }
      response
        ..writeln()
        ..write('The user already sees these files. Do not copy them into your answer.');

      final shown = StringBuffer('> 開発: ${model.label}${done.length > 1 ? '（最大${gate.n}件を同時に）' : ''}\n');
      for (final r in done) {
        shown
          ..writeln()
          ..writeln('### ${r.title}')
          ..writeln()
          ..writeln(r.output);
      }

      return ToolOutcome(
        response.toString(),
        ToolActivity(
          'Delegate',
          '${stopped ? '停止: ' : ''}開発モデル（${model.label}）に ${done.length} 件: ${done.map((r) => r.title).join('、')}',
          failed: done.every((r) => r.failed),
        ),
        shown: shown.toString(),
      );
    } finally {
      if (device) releaseDevice?.call();
    }
  }
}

class _Stored {
  const _Stored(this.id, this.title, this.summary, this.task, this.output, {this.failed = false});

  final String id;
  final String title;
  final String summary;

  /// The job as first given: a correction runs this again with the earlier answer and the feedback.
  final DelegateTask task;
  final String output;
  final bool failed;
}
