import 'dart:convert';

/// One piece of work the design model hands to the developer model.
class CodingTask {
  const CodingTask({required this.id, required this.title, required this.instructions, this.files = const []});

  final String id;
  final String title;

  /// Complete and specific: the developer sees nothing else but this and the plan's summary.
  final String instructions;

  /// The files this task writes, when the design model named them.
  final List<String> files;
}

/// What the design model decided: a summary shared by every task, and the tasks themselves.
class CodingPlan {
  const CodingPlan({required this.summary, required this.tasks});

  final String summary;
  final List<CodingTask> tasks;
}

/// The design model's verdict on what the developers wrote.
class CodingReview {
  const CodingReview({required this.approved, this.notes = '', this.fixes = const {}});

  final bool approved;
  final String notes;

  /// Task id → what to change. Only tasks that need another go are listed.
  final Map<String, String> fixes;
}

/// The "coding mode" settings: which models take which role and how far the work is split.
///
/// A model is named by `providerId|modelId` (`local|` is the model on the device); empty means no
/// model was chosen for that role.
class CodingSettings {
  const CodingSettings({
    this.enabled = false,
    this.planner = '',
    this.developer = '',
    this.maxTasks = 4,
    this.parallel = 3,
    this.reviewRounds = 1,
    this.plannerMaxTokens = 2048,
    this.developerMaxTokens = 4096,
  });

  final bool enabled;
  final String planner;
  final String developer;

  /// Most tasks the design model may split the request into.
  final int maxTasks;

  /// How many developer requests run at the same time (the device model always runs one).
  final int parallel;

  /// How many times the design model may send work back for fixes. 0 skips the review.
  final int reviewRounds;
  final int plannerMaxTokens;
  final int developerMaxTokens;

  /// Whether both roles have a model, so the work can be split at all.
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

/// The wording the two roles are given, and the reading of what they answer.
abstract final class CodingPrompts {
  static String planner(int maxTasks) => '''
You are the architect of a small engineering team. A cheaper developer model writes the code; you do not.
Read the conversation and decide what to do:
- If the user asks a question, a clarification is needed, or the job is too small to split, answer it yourself in plain text (no JSON).
- Otherwise reply with ONLY one JSON object and nothing else:
  {"summary": "<what is being built and every decision the tasks share: language, file layout, names, signatures, data formats>", "tasks": [{"id": "t1", "title": "<short>", "instructions": "<complete, specific instructions>", "files": ["<path>"]}]}
Rules for the tasks:
- At most $maxTasks tasks. Prefer fewer; one is fine for a small job.
- They run at the same time and cannot see each other's output, so write the interfaces between them (names, signatures, formats) into the summary and into every task that touches them.
- Each task's instructions must let a developer who sees nothing else implement it. Each task produces whole files.
- Do not write the implementation yourself.
Reply in the user's language.''';

  static const developer = '''
You are a developer on a team. Implement exactly the task you are given, using the plan's decisions.
- Output complete, runnable files. Put each file in its own fenced code block with the language (```python, ```html ...); write a line "File: <path>" just before the block when a path is given.
- Do not ask questions. If something is unclear, make a reasonable choice and say so in one line.
- Keep any explanation to one or two sentences after the code.
Reply in the user's language.''';

  static String reviewer(int maxTasks) => '''
You are the architect reviewing your developers' work against your plan.
Reply with ONLY one JSON object: {"approved": true|false, "notes": "<one or two sentences>", "fixes": [{"task": "<task id>", "instructions": "<exactly what to change>"}]}
Approve when the work does what the plan says. Ask for fixes only for real defects: missing files, interfaces that do not match between tasks, wrong behaviour. At most $maxTasks fixes.
Reply in the user's language.''';

  /// What a developer is asked, for one task.
  static String developerTask(String request, CodingPlan plan, CodingTask task) {
    final b = StringBuffer()
      ..writeln('# What the user asked for')
      ..writeln(request.trim())
      ..writeln()
      ..writeln('# The plan (shared by every task)')
      ..writeln(plan.summary.trim())
      ..writeln()
      ..writeln('# Your task: ${task.title}')
      ..writeln(task.instructions.trim());
    if (task.files.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Files to write: ${task.files.join(', ')}');
    }
    return b.toString();
  }

  /// What the design model reads to judge the work. Each result is cut to [perTaskChars] so a long
  /// answer cannot make the review as costly as the work itself.
  static String reviewInput(String request, CodingPlan plan, Map<String, String> results, {int perTaskChars = 6000}) {
    final b = StringBuffer()
      ..writeln('# What the user asked for')
      ..writeln(request.trim())
      ..writeln()
      ..writeln('# Your plan')
      ..writeln(plan.summary.trim());
    for (final task in plan.tasks) {
      final result = results[task.id] ?? '(no result)';
      final shown = result.length > perTaskChars ? '${result.substring(0, perTaskChars)}\n[… cut …]' : result;
      b
        ..writeln()
        ..writeln('# Task ${task.id}: ${task.title}')
        ..writeln('Instructions: ${task.instructions.trim()}')
        ..writeln()
        ..writeln('Developer output:')
        ..writeln(shown);
    }
    return b.toString();
  }

  /// The text between the first `{` and the last `}`, with a code fence around it removed; null
  /// when there is no object in [text].
  static String? jsonObjectIn(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    return text.substring(start, end + 1);
  }

  /// Reads the design model's answer. Null means it did not give a plan: the answer is plain
  /// text for the user (a question, or a reply too small to split) and is shown as it is.
  static CodingPlan? parsePlan(String text, {required int maxTasks}) {
    final raw = jsonObjectIn(text);
    if (raw == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final list = decoded['tasks'];
    if (list is! List) return null;

    final tasks = <CodingTask>[];
    final seen = <String>{};
    for (final item in list) {
      if (item is! Map) continue;
      final instructions = _text(item['instructions'] ?? item['description'] ?? item['detail']);
      if (instructions.isEmpty) continue;
      var id = _text(item['id']);
      if (id.isEmpty || !seen.add(id)) id = _freshId(seen, tasks.length + 1);
      seen.add(id);
      final title = _text(item['title']);
      tasks.add(
        CodingTask(
          id: id,
          title: title.isEmpty ? 'タスク ${tasks.length + 1}' : title,
          instructions: instructions,
          files: [
            if (item['files'] is List)
              for (final f in item['files'] as List)
                if (f is String && f.trim().isNotEmpty) f.trim(),
          ],
        ),
      );
      if (tasks.length >= maxTasks) break;
    }
    if (tasks.isEmpty) return null;
    return CodingPlan(summary: _text(decoded['summary']), tasks: tasks);
  }

  /// Reads the review. Anything unreadable counts as approval: the work is shown either way, and
  /// a design model that cannot be understood must not make the developers redo it for nothing.
  static CodingReview parseReview(String text, {required Set<String> taskIds}) {
    final raw = jsonObjectIn(text);
    if (raw == null) return const CodingReview(approved: true);
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const CodingReview(approved: true);
    }
    if (decoded is! Map) return const CodingReview(approved: true);

    final fixes = <String, String>{};
    final list = decoded['fixes'];
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        final task = _text(item['task'] ?? item['id']);
        final instructions = _text(item['instructions'] ?? item['fix']);
        if (taskIds.contains(task) && instructions.isNotEmpty) fixes[task] = instructions;
      }
    }
    final approved = decoded['approved'] is bool ? decoded['approved'] as bool : fixes.isEmpty;
    return CodingReview(approved: approved || fixes.isEmpty, notes: _text(decoded['notes']), fixes: fixes);
  }

  static String _text(Object? value) => value is String ? value.trim() : (value is num ? '$value' : '');

  static String _freshId(Set<String> taken, int from) {
    for (var n = from;; n++) {
      if (!taken.contains('t$n')) return 't$n';
    }
  }
}
