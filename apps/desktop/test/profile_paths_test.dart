import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/profile_paths.dart';

void main() {
  test('canonical profile ignores independent legacy sessions', () {
    final root = Directory(
      Directory.systemTemp
          .createTempSync('foresight-profile-')
          .resolveSymbolicLinksSync(),
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final env = {
      'HOME': root.path,
      'XDG_DATA_HOME': root.path,
      'XDG_RUNTIME_DIR': '/run/test',
    };
    expect(
      ProfilePaths.resolve(env, macOS: false).data,
      '${root.path}/open-foresight',
    );
    // The independently running virtual session must never become our default.
    File(
      '${root.path}/foresight-linux/application.db',
    ).createSync(recursive: true);
    expect(
      ProfilePaths.resolve(env, macOS: false).runtime,
      '/run/test/open-foresight',
    );
    File(
      '${root.path}/foresight-linux-desktop/application.db',
    ).createSync(recursive: true);
    expect(
      ProfilePaths.resolve(env, macOS: false).data,
      '${root.path}/open-foresight',
    );
    expect(
      ProfilePaths.resolve(env, macOS: false).runtime,
      '/run/test/open-foresight',
    );
    File('${root.path}/foresight/application.db').createSync(recursive: true);
    expect(
      ProfilePaths.resolve(env, macOS: false).data,
      '${root.path}/open-foresight',
    );
    final explicit = ProfilePaths.resolve({
      ...env,
      'FORESIGHT_DATA': '/private',
      'FORESIGHT_RUNTIME': '/socket',
    }, macOS: false);
    expect(explicit.data, '/private');
    expect(explicit.runtime, '/socket');
  });
}
