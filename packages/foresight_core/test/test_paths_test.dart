import 'dart:io';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Directory synchronous;
  late Directory asynchronous;
  group('temporary fixture lifetime', () {
    setUp(() {
      synchronous = createTestTempDirectorySync('temp-helper-sync-');
      addTearDown(() {
        // Resources registered after allocation close before directory cleanup.
        expect(synchronous.existsSync(), isTrue);
      });
    });
    test(
      'creates sync and async directories under the configured root',
      () async {
        asynchronous = await createTestTempDirectory('temp-helper-async-');
        final expected = shortTestTempRoot.absolute.resolveSymbolicLinksSync();
        expect(synchronous.parent.resolveSymbolicLinksSync(), expected);
        expect(asynchronous.parent.resolveSymbolicLinksSync(), expected);
        File('${synchronous.path}/marker').writeAsStringSync('fixture');
        File('${asynchronous.path}/marker').writeAsStringSync('fixture');
      },
    );
  });
  test('removes directories after the previous test', () {
    expect(synchronous.existsSync(), isFalse);
    expect(asynchronous.existsSync(), isFalse);
  });
  test('default root keeps macOS socket paths short and honors overrides', () {
    final override = Platform.environment['FORESIGHT_TEST_TEMP_ROOT'];
    expect(
      shortTestTempRoot.path,
      override ?? (Platform.isMacOS ? '/tmp' : Directory.systemTemp.path),
    );
  });
  test('early explicit removal is safe', () async {
    createTestTempDirectorySync('temp-helper-early-').deleteSync();
    await (await createTestTempDirectory('temp-helper-early-')).delete();
  });
}
