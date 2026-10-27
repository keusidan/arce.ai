import 'protocol.dart';

/// The "coding mode" settings: which models take which role and how far the work is split.
///
/// The planner is the model that answers the user. It decides what to split, hands the jobs to the
/// developer with the `delegate` tool, reads what comes back, and sends work back if it is wrong.
/// The app only carries the jobs out (all at once, up to the limit). A model is named by
/// `providerId|modelId` (`local|` is the model on the device); empty means none was chosen.
class CodingSettings {
  const CodingSettings({
    this.enabled = false,
    this.planner = '',
    this.developer = '',
    this.maxTasks = 4,
    this.parallel = 3,
    this.reviewRounds = 1,
    this.developerMaxTokens = 0,
    this.resultChars = 12000,
  });

  final bool enabled;
  final String planner;
  final String developer;

  /// Most jobs one `delegate` call may carry; the planner is told, and the rest is refused.
  final int maxTasks;

  /// How many developer requests run at the same time (the device model always runs one).
  final int parallel;

  /// How many times the planner is told it may send work back for fixes. 0 tells it not to review.
  final int reviewRounds;

  /// The longest reply of one developer job; 0 lets the model's own settings decide (the maker's
  /// recommendation, then what the role usually needs). A reasoning model spends part of the
  /// budget on thinking, so a small fixed number cuts its answer short.
  final int developerMaxTokens;

  /// How much of each developer result the planner reads. The user sees all of it.
  final int resultChars;

  /// Whether both roles have a model, so the work can be handed over at all.
  bool get isReady => enabled && planner.isNotEmpty && developer.isNotEmpty;

  static const localProvider = 'local';

  /// `provider|model` of a reference, or null for an empty or malformed one.
  static (String provider, String model)? parseRef(String ref) {
    final at = ref.indexOf('|');
    if (at <= 0) return null;
    return (ref.substring(0, at), ref.substring(at + 1));
  }

  static String ref(String provider, String model) => '$provider|$model';
}

/// The wording the planner and the developer are given.
abstract final class CodingPrompts {
  /// What the planner is told about its team, added to its instructions while the coding mode is on.
  static String plannerInstructions({required int maxTasks, required int reviewRounds}) => '''
Coding mode: you lead a small team. A cheaper developer model writes the long code; you decide, hand over and check.
- For a question, a clarification, or a job of a few lines, answer yourself and do not use delegate.
- For anything bigger, call delegate. At most $maxTasks tasks per call. They run at the same time and cannot see each other's output, so write every name, signature and data format they must agree on into summary and into each task that touches it. Each task's instructions must let a developer who sees nothing else implement it, and each task produces whole files.
- The user sees the developers' files as they come in. Do not copy them into your answer and do not write the implementation yourself.
- Read what comes back. ${reviewRounds <= 0 ? 'Do not send work back; accept the result.' : 'If something is really wrong (a missing file, interfaces that do not match, wrong behaviour), call delegate again with revise set to that result\'s id and exactly what to change, at most $reviewRounds times.'}
- Finish with a short summary of what was built and anything the user must do. Reply in the user's language.''';

  static const developer = '''
You are a developer on a team. Implement exactly the task you are given, using the plan's decisions.
- Output complete, runnable files. Put each file in its own fenced code block with the language (```python, ```html ...); write a line "File: <path>" just before the block when a path is given.
- Do not ask questions. If something is unclear, make a reasonable choice and say so in one line.
- Keep any explanation to one or two sentences after the code.
Reply in the user's language.''';

  /// What a developer is asked, for one job.
  static String developerTask(String summary, DelegateTask task) {
    final b = StringBuffer();
    if (summary.trim().isNotEmpty) {
      b
        ..writeln('# The plan (shared by every task)')
        ..writeln(summary.trim())
        ..writeln();
    }
    b
      ..writeln('# Your task: ${task.title}')
      ..writeln(task.instructions.trim());
    if (task.files.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Files to write: ${task.files.join(', ')}');
    }
    return b.toString();
  }

  /// What a developer is told when its earlier answer has to be corrected.
  static String correction(String feedback) =>
      'Reviewer feedback:\n${feedback.trim()}\n\nFix it and output the complete corrected files.';
}
