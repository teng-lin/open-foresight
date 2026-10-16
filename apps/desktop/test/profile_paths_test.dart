import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight/profile_paths.dart';

void main() {
  test(
    'new installs use foresight; existing desktop data and socket stay paired',
    () {
      final root = Directory.systemTemp.createTempSync('foresight-profile-');
      addTearDown(() => root.deleteSync(recursive: true));
      final env = {
        'HOME': root.path,
        'XDG_DATA_HOME': root.path,
        'XDG_RUNTIME_DIR': '/run/test',
      };
      expect(ProfilePaths.resolve(env).data, '${root.path}/foresight');
      // The independently running virtual session must never become our default.
      File(
        '${root.path}/foresight-linux/application.db',
      ).createSync(recursive: true);
      expect(ProfilePaths.resolve(env).runtime, '/run/test/foresight');
      File(
        '${root.path}/foresight-linux-desktop/application.db',
      ).createSync(recursive: true);
      expect(
        ProfilePaths.resolve(env).data,
        '${root.path}/foresight-linux-desktop',
      );
      expect(
        ProfilePaths.resolve(env).runtime,
        '/run/test/foresight-linux-desktop',
      );
      File('${root.path}/foresight/application.db').createSync(recursive: true);
      expect(ProfilePaths.resolve(env).data, '${root.path}/foresight');
      final explicit = ProfilePaths.resolve({
        ...env,
        'FORESIGHT_DATA': '/private',
        'FORESIGHT_RUNTIME': '/socket',
      });
      expect(explicit.data, '/private');
      expect(explicit.runtime, '/socket');
    },
  );
}
