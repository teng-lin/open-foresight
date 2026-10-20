import 'package:crypto/crypto.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/src/profile_paths.dart';

/// The first 12 hex digits of the SHA-256 of a canonical data path, computed
/// here rather than through ProfilePaths.
String profileHash(String data) =>
    sha256.convert(utf8.encode(data)).toString().substring(0, 12);

void main() {
  test('canonical profile ignores independent legacy sessions', () {
    final root = Directory(
      createTestTempDirectorySync(
        'foresight-profile-',
      ).resolveSymbolicLinksSync(),
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final env = {
      'HOME': root.path,
      'XDG_DATA_HOME': root.path,
      'XDG_RUNTIME_DIR': '/run/test',
    };
    final runtime =
        '/run/test/open-foresight/${profileHash('${root.path}/open-foresight')}';
    expect(
      ProfilePaths.resolve(env, macOS: false).data,
      '${root.path}/open-foresight',
    );
    // The independently running virtual session must never become our default.
    File(
      '${root.path}/foresight-linux/application.db',
    ).createSync(recursive: true);
    expect(ProfilePaths.resolve(env, macOS: false).runtime, runtime);
    File(
      '${root.path}/foresight-linux-desktop/application.db',
    ).createSync(recursive: true);
    expect(
      ProfilePaths.resolve(env, macOS: false).data,
      '${root.path}/open-foresight',
    );
    expect(ProfilePaths.resolve(env, macOS: false).runtime, runtime);
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

  test('two profiles get different default runtimes on Linux, and macOS is '
      'unchanged (D5)', () {
    final root = Directory(
      createTestTempDirectorySync('of-runtimes-').resolveSymbolicLinksSync(),
    );
    ProfilePaths profile(String name, Map<String, String> environment) =>
        ProfilePaths.resolve({
          'HOME': root.path,
          'FORESIGHT_DATA': '${root.path}/$name',
          ...environment,
        }, macOS: false);
    final xdg = {'XDG_RUNTIME_DIR': '/run/test'};
    final first = profile('first', xdg), second = profile('second', xdg);
    expect(
      first.runtime,
      '/run/test/open-foresight/${profileHash('${root.path}/first')}',
    );
    expect(
      second.runtime,
      '/run/test/open-foresight/${profileHash('${root.path}/second')}',
    );
    expect(first.runtime, isNot(second.runtime));
    // Without XDG_RUNTIME_DIR the runtime is private to the profile too.
    expect(
      profile('first', const {}).runtime,
      '${root.path}/first/runtime/${profileHash('${root.path}/first')}',
    );
    // macOS already had a runtime per profile.
    final mac = ProfilePaths.resolve({
      'HOME': root.path,
      'FORESIGHT_DATA': '${root.path}/first',
      'TMPDIR': root.path,
    }, macOS: true);
    expect(mac.runtime, '${root.path}/of-${profileHash('${root.path}/first')}');
  });

  test('identity hashes the canonical data path, so an alias of a profile '
      'shares it and another profile does not', () {
    final root = Directory(
      createTestTempDirectorySync('of-identity-').resolveSymbolicLinksSync(),
    );
    final data = '${root.path}/profile/data';
    Directory(data).createSync(recursive: true);
    Link('${root.path}/alias').createSync('${root.path}/profile');
    final canonical = ProfilePaths(data, '${root.path}/run');
    final identity = sha256
        .convert(utf8.encode(data))
        .toString()
        .substring(0, 24);
    expect(canonical.identity, identity);
    expect(
      ProfilePaths('${root.path}/alias/data', '/elsewhere').identity,
      identity,
    );
    // A data directory not created yet keeps its identity once it exists.
    final later = ProfilePaths('${root.path}/alias/later', '/elsewhere');
    final before = later.identity;
    Directory('${root.path}/profile/later').createSync();
    expect(later.identity, before);
    expect(
      ProfilePaths('${root.path}/profile/other', '/elsewhere').identity,
      isNot(identity),
    );
    // The default runtime is named by the same identity.
    expect(
      ProfilePaths.resolve({
        'HOME': root.path,
        'FORESIGHT_DATA': '${root.path}/alias/data',
        'XDG_RUNTIME_DIR': '/run/test',
      }, macOS: false).runtime,
      '/run/test/open-foresight/${identity.substring(0, 12)}',
    );
  });
}
