import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test('aliased profiles share canonical runtime and its protected parent', () {
    final root = createTestTempDirectorySync('profile-boundary-');
    addTearDown(() => root.deleteSync(recursive: true));
    final real = Directory('${root.path}/real')..createSync();
    final alias = Link('${root.path}/alias')..createSync(real.path);
    ProfilePaths resolve(String data) => ProfilePaths.resolve({
      'HOME': root.path,
      'FORESIGHT_DATA': data,
      'XDG_RUNTIME_DIR': '${alias.path}/run',
    }, macOS: false);
    final original = resolve('${real.path}/not-yet-created');
    final throughAlias = resolve('${alias.path}/not-yet-created');
    expect(throughAlias.identity, original.identity);
    expect(throughAlias.data, original.data);
    expect(throughAlias.runtime, original.runtime);
    expect(
      throughAlias.runtimeParent,
      '${real.resolveSymbolicLinksSync()}/run/open-foresight',
    );
    expect(Directory(original.data).existsSync(), isFalse);
    expect(Directory(original.runtime).existsSync(), isFalse);
    Directory(original.data).createSync();
    expect(
      resolve('${alias.path}/not-yet-created').identity,
      original.identity,
    );
    expect(resolve('${real.path}/other').identity, isNot(original.identity));
  });

  test('socket path admission counts UTF-8 bytes instead of characters', () {
    final root = createTestTempDirectorySync('profile-byte-boundary-');
    addTearDown(() => root.deleteSync(recursive: true));
    final fits = '/${'é' * 44}r';
    expect(utf8.encode('$fits/application.sock').length, 107);
    final env = {'HOME': root.path, 'FORESIGHT_DATA': '${root.path}/data'};
    expect(
      ProfilePaths.resolve({
        ...env,
        'FORESIGHT_RUNTIME': fits,
      }, macOS: false).runtime,
      fits,
    );
    expect(
      () => ProfilePaths.resolve({
        ...env,
        'FORESIGHT_RUNTIME': '${fits}r',
      }, macOS: false),
      throwsA(
        isA<StateError>().having(
          (e) => '$e',
          'reason',
          contains('Unix sockets'),
        ),
      ),
    );
  });
}
