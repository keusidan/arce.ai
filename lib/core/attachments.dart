/// A file the user added to a message, already decoded to text.
class Attachment {
  const Attachment(this.name, this.text);
  final String name;
  final String text;
}

/// Keeps attachments from swamping the context window (spec §18): caps the number of files
/// and the characters taken from each and in total, and says so when it cuts.
abstract final class AttachmentPolicy {
  static const maxFiles = 5;
  static const maxCharsPerFile = 8000;
  static const maxTotalChars = 16000;

  static String compose(String text, List<Attachment> attachments) {
    if (attachments.isEmpty) return text;
    var budget = maxTotalChars;
    final b = StringBuffer();
    for (final file in attachments.take(maxFiles)) {
      final limit = budget < maxCharsPerFile ? budget : maxCharsPerFile;
      final body = file.text.length > limit ? file.text.substring(0, limit) : file.text;
      budget -= body.length;
      b
        ..write('<file name="')
        ..write(file.name.replaceAll('"', "'"))
        ..write('">\n')
        ..write(body);
      if (body.length < file.text.length) {
        b.write('\n[… ${file.text.length - body.length} characters omitted …]');
      }
      b.write('\n</file>\n');
    }
    if (attachments.length > maxFiles) {
      b.write('[${attachments.length - maxFiles} more files not included]\n');
    }
    b.write(text);
    return b.toString();
  }
}
