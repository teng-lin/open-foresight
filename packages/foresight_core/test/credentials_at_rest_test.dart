import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:test/test.dart';
import 'package:foresight_test_support/google_connections.dart';

class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  bool available = true;
  Completer<void>? writeStarted, releaseWrite;
  @override
  Future<bool> write(String key, String value) async {
    if (!available) return false;
    if (writeStarted?.isCompleted == false) writeStarted!.complete();
    await releaseWrite?.future;
    values[key] = value;
    return true;
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  late Directory root;
  late GoogleFixture fixture;
  late File client;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('credentials-at-rest-');
    fixture = GoogleFixture();
    await fixture.start();
    client = File('${root.path}/client.json')
      ..writeAsStringSync(
        jsonEncode({
          'installed': {'client_id': 'fixture.apps.googleusercontent.com'},
        }),
      );
  });
  tearDown(() async {
    await fixture.close();
    root.deleteSync(recursive: true);
  });

  test(
    'new connection stores refresh secret in platform store and reopens',
    () async {
      final secrets = MemorySecrets();
      final directory = Directory('${root.path}/google');
      var auth = GoogleAuth(
        directory,
        endpoints: fixture.endpoints,
        secretStore: secrets,
        defaultClient: client,
      );
      await auth.signIn(fixture.consent);
      final jsonFile = File('${directory.path}/tokens.json');
      final saved = jsonDecode(jsonFile.readAsStringSync()) as Map;
      expect(saved.containsKey('refresh_token'), isFalse);
      expect(saved['refresh_token_store'], 'platform');
      expect(secrets.values.values.single, 'fixture-refresh');
      expect(jsonFile.statSync().mode & 0x1ff, 0x180);
      await auth.close();
      auth = GoogleAuth(
        directory,
        endpoints: fixture.endpoints,
        secretStore: secrets,
        defaultClient: client,
      );
      addTearDown(auth.close);
      expect(auth.connected, isTrue);
      await auth.accessToken(forceRefresh: true);
      expect(fixture.refreshes, 1);
      await auth.disconnect();
      expect(secrets.values, isEmpty);
      expect(jsonFile.existsSync(), isFalse);
    },
  );

  test(
    'forget serializes with an old save and blocks a new sign-in until erasure',
    () async {
      final secrets = MemorySecrets()
        ..writeStarted = Completer<void>()
        ..releaseWrite = Completer<void>();
      final auth = GoogleAuth(
        Directory('${root.path}/racing'),
        endpoints: fixture.endpoints,
        secretStore: secrets,
        defaultClient: client,
      );
      addTearDown(auth.close);
      final signing = expectLater(
        auth.signIn(fixture.consent),
        throwsStateError,
      );
      await secrets.writeStarted!.future;
      final forgetting = auth.forget();
      await expectLater(auth.signIn(fixture.consent), throwsStateError);
      secrets.releaseWrite!.complete();
      await signing;
      await forgetting;
      expect(secrets.values, isEmpty);
      expect(auth.connected, isFalse);
      expect(File('${auth.directory.path}/tokens.json').existsSync(), isFalse);
      secrets.writeStarted = null;
      secrets.releaseWrite = null;
      await auth.signIn(fixture.consent);
      expect(auth.connected, isTrue);
      expect(secrets.values.values.single, 'fixture-refresh');
    },
  );

  test('unavailable platform store uses private file fallback', () async {
    final directory = Directory('${root.path}/fallback');
    final auth = GoogleAuth(
      directory,
      endpoints: fixture.endpoints,
      secretStore: const UnavailableSecretStore(),
      defaultClient: client,
    );
    addTearDown(auth.close);
    await auth.signIn(fixture.consent);
    final file = File('${directory.path}/tokens.json');
    expect(jsonDecode(file.readAsStringSync())['refresh_token'], isA<String>());
    expect(file.statSync().mode & 0x1ff, 0x180);
    expect(directory.statSync().mode & 0x3f, 0);
  });

  for (final directoryMode in ['750', '705']) {
    test('public token directory mode $directoryMode is refused', () async {
      final directory = Directory('${root.path}/public')..createSync();
      final file = File('${directory.path}/tokens.json')
        ..writeAsStringSync(
          jsonEncode({
            'access_token': 'access',
            'refresh_token': 'refresh',
            'account_sub': 'account',
            'expires_at': 1,
          }),
        );
      await Process.run('/bin/chmod', ['600', file.path]);
      await Process.run('/bin/chmod', [directoryMode, directory.path]);
      final auth = GoogleAuth(
        directory,
        secretStore: const UnavailableSecretStore(),
      );
      addTearDown(auth.close);
      expect(auth.connected, isFalse);
      expect(auth.loadError, isNotEmpty);
      expect(directory.statSync().mode & 0x3f, isNonZero);
    });
  }

  test(
    'forget deletes platform secret before best-effort revocation',
    () async {
      final secrets = MemorySecrets();
      final auth = GoogleAuth(
        Directory('${root.path}/forget'),
        endpoints: fixture.endpoints,
        secretStore: secrets,
        defaultClient: client,
      );
      addTearDown(auth.close);
      await auth.signIn(fixture.consent);
      await auth.forget();
      expect(auth.connected, isFalse);
      expect(secrets.values, isEmpty);
    },
  );

  test(
    'exports are private and replace symlinks without changing their target',
    () async {
      final original = File('${root.path}/original')..writeAsStringSync('keep');
      final link = Link('${root.path}/meeting.md')..createSync(original.path);
      await writePrivateTextFile(File(link.path), 'private notes');
      expect(original.readAsStringSync(), 'keep');
      final export = File(link.path);
      expect(export.readAsStringSync(), 'private notes');
      expect(export.statSync().mode & 0x1ff, 0x180);
      expect(root.listSync().whereType<Directory>(), isEmpty);
    },
  );
}
