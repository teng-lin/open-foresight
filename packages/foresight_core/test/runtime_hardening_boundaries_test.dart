import 'sql_support_test_bootstrap.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/src/dedicated_query_acquisition.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

/// Install a derived snapshot; the captured configuration itself is immutable.
void _configure(Map<String, String?> values) =>
    installRuntimeConfiguration(runtimeConfiguration.withOverrides(values));

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  setUp(() {
    root = createTestTempDirectorySync('of-hb-');
    final previous = runtimeConfiguration;
    addTearDown(() => installRuntimeConfiguration(previous));
  });
  test(
    'query distribution terms require HTTPS without embedded credentials',
    () {
      for (final value in [
        null,
        '',
        'http://publisher.example/terms',
        'https:///terms',
        'https://user:secret@publisher.example/terms',
        'file:///tmp/terms',
      ]) {
        _configure({'FORESIGHT_QUERY_TERMS_URL': value});
        expect(dedicatedQueryTermsUri(), isNull, reason: value);
      }
      const valid = 'https://publisher.example/terms?revision=2';
      _configure({'FORESIGHT_QUERY_TERMS_URL': valid});
      expect(dedicatedQueryTermsUri(), Uri.parse(valid));
    },
  );
  test(
    'startup handoff rejects public, oversized and malformed entries without deleting evidence',
    () {
      final directory = Directory('${root.path}/of-launch-fixture')
        ..createSync();
      Process.runSync('/bin/chmod', ['700', directory.path]);
      final handoff = File('${directory.path}/startup.json');
      for (final contents in [
        jsonEncode(['not a map']),
        jsonEncode({'FORESIGHT_DATA': 42}),
        jsonEncode({'PATH': '/attacker'}),
        jsonEncode({'FORESIGHT_STARTUP_ENV': '/recursive'}),
        'x' * 65537,
      ]) {
        handoff.writeAsStringSync(contents);
        protectPrivateFile(handoff.path);
        expect(
          () => consumeServiceStartupEnvironment(handoff.path),
          throwsStateError,
        );
        expect(handoff.readAsStringSync(), contents);
      }
      handoff.writeAsStringSync('{}');
      Process.runSync('/bin/chmod', ['644', handoff.path]);
      expect(
        () => consumeServiceStartupEnvironment(handoff.path),
        throwsStateError,
      );
      expect(handoff.existsSync(), isTrue);
      handoff.deleteSync();
      final target = File('${root.path}/target')..writeAsStringSync('{}');
      Link(handoff.path).createSync(target.path);
      expect(
        () => consumeServiceStartupEnvironment(handoff.path),
        throwsStateError,
      );
      expect(target.readAsStringSync(), '{}');
    },
  );
  test('sealed bundle rejects a manifest lacking its native library', () {
    final resources = Directory('${root.path}/Test.app/Contents/Resources')
      ..createSync(recursive: true);
    File('${resources.path}/runtime.json').writeAsStringSync('{}');
    expect(
      () => RuntimeConfiguration.resolve(
        environment: {'FORESIGHT_NATIVE': '/ambient/native.so'},
        executable: '${resources.parent.path}/MacOS/service',
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('native runtime is missing'),
        ),
      ),
    );
    expect(
      () => validateServiceCompatibility(
        {},
        configuration: RuntimeConfiguration({
          'FORESIGHT_RUNTIME_REVISION': 'revision',
        }),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('installation root'),
        ),
      ),
    );
  });
  test(
    'web search requires both distribution credentials and reuses owned callbacks',
    () async {
      final store = Store('${root.path}/app.db');
      final helper = Helper(
        '${root.path}/helper.sock',
        '${root.path}/helper-data',
        manageProcess: false,
      );
      final domain = Domain(store, helper);
      addTearDown(() async {
        domain.close();
        await helper.close();
        store.close();
      });
      _configure({'FORESIGHT_SEARCH_API_KEY': null});
      _configure({'FORESIGHT_WEB_CONTENT_API_KEY': null});
      expect(domain.webSearchAvailable, isFalse);
      expect(
        domain.searchCallbacks,
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            RpcErrorCode.unavailable,
          ),
        ),
      );
      _configure({'FORESIGHT_SEARCH_API_KEY': 'search-fixture'});
      expect(domain.webSearchAvailable, isFalse);
      _configure({'FORESIGHT_WEB_CONTENT_API_KEY': 'content-fixture'});
      expect(domain.webSearchAvailable, isTrue);
      final callbacks = domain.searchCallbacks();
      expect(identical(domain.searchCallbacks(), callbacks), isTrue);
    },
  );
  test(
    'profile resolution rejects missing home and overlong macOS sockets',
    () {
      expect(
        () => ProfilePaths.resolve({'HOME': ''}, macOS: false),
        throwsStateError,
      );
      final profile = ProfilePaths.resolve({'HOME': root.path}, macOS: false);
      expect(
        profile.data,
        '${root.resolveSymbolicLinksSync()}/.local/share/open-foresight',
      );
      final hash = sha256
          .convert(utf8.encode(profile.data))
          .toString()
          .substring(0, 12);
      expect(profile.runtime, '${profile.data}/runtime/$hash');
      expect(
        () => ProfilePaths.resolve({
          'HOME': root.path,
          'FORESIGHT_RUNTIME': '${root.path}/${'long' * 30}',
        }, macOS: true),
        throwsStateError,
      );
    },
  );
}
