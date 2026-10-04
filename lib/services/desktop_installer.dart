import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Replaces the running desktop build with a downloaded one and starts it again.
///
/// A running program cannot overwrite its own files (Windows locks them), so a small script
/// waits for this process to exit, copies the new files over the old ones and restarts the app.
/// The archive layouts are fixed by the release workflow:
/// - Windows `.zip` and Linux `.tar.gz`: the contents of the build folder (executable at the top)
/// - macOS `.zip`: `ARCE.AI.app` at the top
abstract final class DesktopInstaller {
  static Future<void> apply(File archive) async {
    final temp = await getTemporaryDirectory();
    final work = Directory(p.join(temp.path, 'arce_update'));
    if (await work.exists()) await work.delete(recursive: true);
    final extracted = Directory(p.join(work.path, 'new'));
    await extracted.create(recursive: true);

    await _extract(archive, extracted);

    final script = File(p.join(work.path, Platform.isWindows ? 'update.cmd' : 'update.sh'));
    final executable = Platform.resolvedExecutable;
    final pidText = '$pid';

    if (Platform.isWindows) {
      final installDir = p.dirname(executable);
      await script.writeAsString(_windowsScript);
      await Process.start(
        'cmd',
        ['/c', script.path, pidText, extracted.path, installDir, executable],
        mode: ProcessStartMode.detached,
      );
    } else if (Platform.isMacOS) {
      // .../ARCE.AI.app/Contents/MacOS/arce_ai -> .../ARCE.AI.app
      final bundle = p.dirname(p.dirname(p.dirname(executable)));
      final newBundle = await extracted.list().firstWhere((e) => e.path.endsWith('.app')).then((e) => e.path);
      await script.writeAsString(_macScript);
      await Process.start('/bin/sh', [script.path, pidText, newBundle, bundle], mode: ProcessStartMode.detached);
    } else {
      final installDir = p.dirname(executable);
      await script.writeAsString(_linuxScript);
      await Process.start(
        '/bin/sh',
        [script.path, pidText, extracted.path, installDir, executable],
        mode: ProcessStartMode.detached,
      );
    }
    exit(0);
  }

  static Future<void> _extract(File archive, Directory into) async {
    final ProcessResult result;
    if (Platform.isMacOS) {
      // ditto keeps permissions and the app bundle's symlinks, which a plain unzip can lose
      result = await Process.run('/usr/bin/ditto', ['-x', '-k', archive.path, into.path]);
    } else if (Platform.isWindows) {
      // Windows 10+ ships bsdtar as tar.exe, which also reads .zip
      result = await Process.run('tar', ['-xf', archive.path, '-C', into.path]);
    } else {
      result = await Process.run('tar', ['-xzf', archive.path, '-C', into.path]);
    }
    if (result.exitCode != 0) throw StateError('アップデートを展開できませんでした: ${result.stderr}');
  }

  static const _windowsScript = r'''@echo off
rem args: pid, new files dir, install dir, executable
:wait
tasklist /FI "PID eq %1" 2>nul | find "%1" >nul
if not errorlevel 1 (
  ping -n 2 127.0.0.1 >nul
  goto wait
)
xcopy /E /Y /I /Q "%~2\*" "%~3\" >nul
start "" "%~4"
''';

  static const _linuxScript = r'''#!/bin/sh
# args: pid, new files dir, install dir, executable
while kill -0 "$1" 2>/dev/null; do sleep 0.5; done
cp -a "$2"/. "$3"/
chmod +x "$4"
nohup "$4" >/dev/null 2>&1 &
''';

  static const _macScript = r'''#!/bin/sh
# args: pid, new .app, installed .app
while kill -0 "$1" 2>/dev/null; do sleep 0.5; done
# keep the old app until the new one is in place, so a failed copy never leaves nothing
rm -rf "$3.old"
mv "$3" "$3.old" || exit 1
if /usr/bin/ditto "$2" "$3"; then
  rm -rf "$3.old"
else
  rm -rf "$3"
  mv "$3.old" "$3"
fi
/usr/bin/xattr -dr com.apple.quarantine "$3" 2>/dev/null
open "$3"
''';
}
