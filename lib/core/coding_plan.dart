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
    this.plannerFollowsModel = true,
    this.developer = '',
    this.moreDevelopers = const [],
    this.maxTasks = 8,
    this.parallel = 4,
    this.reviewRounds = 1,
    this.developerMaxTokens = 0,
    this.resultChars = 12000,
  });

  final bool enabled;
  final String planner;

  /// The planner is the model in use (the one picked in the chat), whatever [planner] says. Without
  /// this, switching the model in the chat changed nothing for the coding agent: its requests kept
  /// going to the planner chosen on the settings screen.
  final bool plannerFollowsModel;

  /// The developer model, and more of them: the jobs of one call are spread over all of them, so
  /// several models write at the same time.
  final String developer;
  final List<String> moreDevelopers;

  /// Every developer model, the first one first, without empty entries and repeats.
  List<String> get developers => <String>{
        if (developer.isNotEmpty) developer,
        for (final d in moreDevelopers)
          if (d.trim().isNotEmpty) d.trim(),
      }.toList();

  /// Most jobs one `delegate` call may carry; the planner is told, and the rest is refused.
  final int maxTasks;

  /// How many requests run at the same time on one developer model (the device model always runs one).
  final int parallel;

  /// How many times the planner is told it may send work back for fixes. 0 tells it not to review.
  final int reviewRounds;

  /// The longest reply of one developer job; 0 lets the model's own settings decide (the maker's
  /// recommendation, then what the role usually needs). A reasoning model spends part of the
  /// budget on thinking, so a small fixed number cuts its answer short.
  final int developerMaxTokens;

  /// How much of each developer result the planner reads. The user sees all of it.
  final int resultChars;

  /// Whether the developers have a model and the planner is known (the model in use, or one chosen),
  /// so the work can be handed over at all.
  bool get isReady => enabled && developers.isNotEmpty && (plannerFollowsModel || planner.isNotEmpty);

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
Coding mode: you lead a team of developer models that write at the same time. You split, they build, you check.
- For a question, a clarification, or a job of a few lines, answer yourself and do not use delegate.
- For anything bigger, call delegate once. Split the work into many SMALL goals (one file, or one group of functions, each), at most $maxTasks per call. Fine-grained jobs finish sooner and fit cheap models.
- Draw the split in plan as a Mermaid flowchart: flowchart TD, one node per job written id["title"], and an arrow a --> b only when b really needs the result of a. Jobs with no arrow into them start at once on different models, so keep as many independent as you can; a job that waits is given the results it waits for. Give the same id to the node and to the task.
- Jobs that run at the same time cannot see each other: write every name, signature and data format they must agree on into summary and into each task that touches it. Each task's instructions must let a developer who sees nothing else implement it; each task produces whole files.
- The developers decide every detail themselves and do not ask you; you get the results only. Do not write the implementation yourself, and do not copy their files into your answer: the user sees them as they come in.
- Read what comes back. ${reviewRounds <= 0 ? 'Do not send work back; accept the result.' : 'If something is really wrong (a missing file, interfaces that do not match, wrong behaviour), call delegate again with revise set to that result\'s id and exactly what to change, at most $reviewRounds times.'}
- To have a command-line coding agent in the Linux environment build it instead (for example opencode, only when the user asks for that): write this same plan to /workspace/PLAN.md with run_command (the flowchart, then each task with its instructions and files), start the agent on that file with shell_session (or with run_command when the agent has a one-shot mode), and read its screen until it is done. The diagram says what depends on what, so tell it to follow it.
- Finish with a short summary of what was built and anything the user must do. Reply in the user's language.''';

  static const developer = '''
You are a developer on a team. Implement exactly the task you are given, using the plan's decisions. Nobody is available to answer you: decide every detail yourself.
- Output complete, runnable files. Put each file in its own fenced code block with the language (```python, ```html ...); write a line "File: <path>" just before the block when a path is given.
- If something is unclear, make the most reasonable choice and say so in one line. Do not ask. Only when it is impossible to go on without a decision that was not given, answer with one line that starts with "QUESTION:" and nothing else.
- When the task lists results of the jobs it waited for, build on them exactly: use their names, signatures and files as they are.
- Keep any explanation to one or two sentences after the code.
Reply in the user's language.''';

  /// Said to a developer that asked a question, once: the planner is not asked, the developer decides.
  static const decideYourself =
      'Nobody can answer this. Decide yourself with the most reasonable choice, say which in one line, and output the complete files now.';

  /// The text of a developer's question, or null when [answer] is not one. A question is the whole
  /// answer: it starts with `QUESTION:` (case does not matter).
  static String? questionIn(String answer) {
    final match = RegExp(r'^question\s*[:：]\s*(.+)$', caseSensitive: false, dotAll: true).firstMatch(answer.trim());
    final question = match?.group(1)?.trim();
    return question == null || question.isEmpty ? null : question;
  }

  /// The paths a developer named in "File: path" lines, in order, without repeats.
  static List<String> filesIn(String answer) {
    final seen = <String>{};
    for (final m in RegExp(r'^\s*File\s*[:：]\s*`?([^\s`]+)`?\s*$', multiLine: true).allMatches(answer)) {
      seen.add(m.group(1)!);
    }
    return seen.toList();
  }

  /// What a developer is asked, for one job.
  ///
  /// [given] are the results of the jobs this one waited for (id -> title and answer): it builds on them.
  static String developerTask(String summary, DelegateTask task, {List<(String id, String title, String answer)> given = const []}) {
    final b = StringBuffer();
    if (summary.trim().isNotEmpty) {
      b
        ..writeln('# The plan (shared by every task)')
        ..writeln(summary.trim())
        ..writeln();
    }
    for (final (id, title, answer) in given) {
      b
        ..writeln('# Result of the job you waited for: $id — $title')
        ..writeln(answer.trim())
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
