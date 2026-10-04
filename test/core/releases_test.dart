import 'package:arce_ai/core/releases.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('versions compare numerically and pre-releases sort first', () {
    expect(Version.parse('v0.1.10')! > Version.parse('0.1.9')!, isTrue);
    expect(Version.parse('1.0.0')! > Version.parse('1.0.0-beta')!, isTrue);
    expect(Version.parse('0.1.0-dev'), const Version(0, 1, 0, 'dev'));
    expect(Version.parse('latest'), isNull);
  });

  test('release json yields one asset and checksum per platform', () {
    final release = ReleaseParser.parse('''{"tag_name":"v0.4.1","body":"notes","html_url":"https://github.com/x/y/releases/tag/v0.4.1","assets":[
      {"id":1,"name":"ARCE.AI-v0.4.1-android.apk","size":10117153},
      {"id":2,"name":"ARCE.AI-v0.4.1-android.apk.sha256","size":85},
      {"id":3,"name":"ARCE.AI-v0.4.1-windows-x64.zip","size":99},
      {"id":4,"name":"ARCE.AI-v0.4.1-linux-x64.tar.gz","size":98}]}''')!;
    expect(release.version, const Version(0, 4, 1));
    final apk = release.assetFor(UpdateTarget.android)!;
    expect(apk.id, 1);
    expect(release.checksumFor(apk)!.id, 2);
    expect(release.assetFor(UpdateTarget.windows)!.id, 3);
    expect(release.assetFor(UpdateTarget.linux)!.id, 4);
    expect(release.assetFor(UpdateTarget.macos), isNull);
    expect(ReleaseParser.parseChecksum('${'ab' * 32}  ARCE.AI-v0.4.1-android.apk\n'), 'ab' * 32);
    expect(ReleaseParser.parseChecksum('nope'), isNull);
  });
}
