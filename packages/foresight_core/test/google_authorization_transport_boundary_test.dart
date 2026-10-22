import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class _RollbackSecrets implements SecretStore {
  String value = 'previous-private-fixture';
  final writes = <String>[];
  @override
  Future<String?> read(String key) async => value;
  @override
  Future<bool> write(String key, String value) async {
    this.value = value;
    writes.add(value);
    return true;
  }

  @override
  Future<void> delete(String key) async =>
      throw StateError('Previous secret must be restored');
}

void main() {
  late Directory root;
  late GoogleFixture fixture;
  setUp(() async {
    root = createTestTempDirectorySync('google-authorization-boundaries-');
    fixture = GoogleFixture();
    await fixture.start();
    addTearDown(() async {
      await fixture.close();
      root.deleteSync(recursive: true);
    });
  });
  GoogleAuth create({GoogleEndpoints? endpoints, SecretStore? secrets}) =>
      GoogleAuth(
        Directory('${root.path}/google'),
        endpoints: endpoints ?? fixture.endpoints,
        secretStore: secrets ?? const UnavailableSecretStore(),
      )..client = GoogleClient('fixture.apps.googleusercontent.com', '');

  test(
    'browser launch failure closes authorization listener and allows a fresh sign-in',
    () async {
      final auth = create();
      addTearDown(auth.close);
      Uri? callback;
      await expectLater(
        auth.signIn((uri) async {
          callback = Uri.parse(uri.queryParameters['redirect_uri']!);
          throw StateError('fixture browser refused');
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            'fixture browser refused',
          ),
        ),
      );
      expect(auth.signingIn, isFalse);
      expect(auth.connected, isFalse);
      final browser = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      addTearDown(() => browser.close(force: true));
      await expectLater(
        browser.getUrl(callback!),
        throwsA(isA<SocketException>()),
      );
      await auth.signIn(fixture.consent);
      expect(auth.connected, isTrue);
      await expectLater(
        auth.signIn(fixture.consent),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('Disconnect'),
          ),
        ),
      );
    },
  );

  for (final missing in ['scope', 'refresh_token']) {
    test('incomplete $missing consent cannot persist authorization', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        expect(request.method, 'POST');
        final form = Uri.splitQueryString(
          await utf8.decoder.bind(request).join(),
        );
        expect(form['grant_type'], 'authorization_code');
        expect(form['code'], 'fixture-code');
        expect(form['code_verifier'], isNotEmpty);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'access_token': 'fixture-access-0',
            'expires_in': 3600,
            if (missing != 'refresh_token') 'refresh_token': 'fixture-refresh',
            if (missing != 'scope') 'scope': GoogleAuth.scopes.join(' '),
          }),
        );
        await request.response.close();
      });
      final auth = create(
        endpoints: GoogleEndpoints(
          authorize: fixture.endpoints.authorize,
          token: Uri.parse('http://127.0.0.1:${server.port}/token'),
          userinfo: fixture.endpoints.userinfo,
        ),
      );
      addTearDown(auth.close);
      await expectLater(
        auth.signIn(fixture.consent),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains(missing == 'scope' ? 'read access' : 'persistent account'),
          ),
        ),
      );
      expect(requests, 1);
      expect(auth.connected, isFalse);
      expect(auth.signingIn, isFalse);
      expect(File('${auth.directory.path}/tokens.json').existsSync(), isFalse);
    });
  }

  test(
    'failed atomic registry adoption restores the prior secured credential',
    () async {
      final secrets = _RollbackSecrets();
      final auth = create(secrets: secrets);
      addTearDown(auth.close);
      final blocked = Directory('${auth.directory.path}/tokens.json')
        ..createSync(recursive: true);
      expect(
        (await Process.run('/bin/chmod', [
          '700',
          auth.directory.path,
        ])).exitCode,
        0,
      );
      final marker = File('${blocked.path}/owned-marker')
        ..writeAsStringSync('retain');
      await expectLater(
        auth.signIn(fixture.consent),
        throwsA(isA<FileSystemException>()),
      );
      expect(secrets.writes, ['fixture-refresh', 'previous-private-fixture']);
      expect(secrets.value, 'previous-private-fixture');
      expect(auth.connected, isFalse);
      expect(marker.readAsStringSync(), 'retain');
      expect(
        auth.directory.listSync().whereType<File>().where(
          (f) => f.path.contains('.tokens.json-'),
        ),
        isEmpty,
      );
    },
  );
}
