import 'package:foresight_core/src/rpc_error.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class MemoryProfileSecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<bool> write(String key, String value) async {
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
  late HttpServer identityServer;
  late GoogleEndpoints endpoints;
  late GoogleAuth auth;
  SecretStore secrets = const UnavailableSecretStore();
  var identity = <String, Object?>{};
  Completer<void>? identityBarrier;
  var identityRequests = 0;
  var driveRequests = 0;
  var driveStatus = 200;
  var driveProfile = <String, Object?>{};

  GoogleAuth createAuth() =>
      GoogleAuth(root, secretStore: secrets, endpoints: endpoints)
        ..client = GoogleClient('fixture.apps.googleusercontent.com', '');

  setUp(() async {
    secrets = const UnavailableSecretStore();
    root = createTestTempDirectorySync('google-profile-');
    Process.runSync('/bin/chmod', ['700', root.path]);
    fixture = GoogleFixture();
    await fixture.start();
    identityRequests = 0;
    driveRequests = 0;
    driveStatus = 200;
    driveProfile = {};
    identityBarrier = null;
    identity = {
      'sub': fixture.accountSub,
      'email': 'fixture@example.test',
      'name': 'Fixture Person',
      'picture': 'https://lh3.googleusercontent.com/fixture',
    };
    identityServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    identityServer.listen((request) async {
      Object response;
      if (request.uri.path == '/drive/about') {
        driveRequests++;
        request.response.statusCode = driveStatus;
        expect(
          request.uri.queryParameters['fields'],
          'user(displayName,photoLink,emailAddress)',
        );
        expect(
          request.headers.value('authorization'),
          startsWith('Bearer fixture-access'),
        );
        response = {'user': driveProfile};
      } else {
        identityRequests++;
        await identityBarrier?.future;
        response = identity;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    endpoints = GoogleEndpoints(
      authorize: fixture.endpoints.authorize,
      token: fixture.endpoints.token,
      revoke: fixture.endpoints.revoke,
      userinfo: Uri.parse('http://127.0.0.1:${identityServer.port}/userinfo'),
      drive: Uri.parse('http://127.0.0.1:${identityServer.port}/drive/'),
    );
    auth = createAuth();
  });

  tearDown(() async {
    identityBarrier?.complete();
    await auth.close();
    await identityServer.close(force: true);
    await fixture.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> reloadLegacy() async {
    await auth.close();
    final file = File('${root.path}/tokens.json');
    final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    saved.remove('name');
    saved.remove('picture');
    file.writeAsStringSync(jsonEncode(saved));
    auth = createAuth();
  }

  test(
    'profile consent and identity survive reload and disappear on logout',
    () async {
      await auth.signIn((uri) async {
        expect(uri.queryParameters['scope']!.split(' '), contains('profile'));
        await fixture.consent(uri);
      });
      expect(auth.displayName, 'Fixture Person');
      expect(auth.photoUrl, identity['picture']);
      await auth.close();
      auth = createAuth();
      expect(auth.connected, isTrue);
      expect(auth.displayName, 'Fixture Person');
      expect(auth.photoUrl, identity['picture']);
      await auth.disconnect();
      expect(auth.displayName, isEmpty);
      expect(auth.photoUrl, isEmpty);
    },
  );

  test(
    'existing tokens acquire profile without another consent and persist it',
    () async {
      await auth.signIn(fixture.consent);
      await reloadLegacy();
      expect(auth.connected, isTrue);
      expect(auth.displayName, isEmpty);
      expect(auth.photoUrl, isEmpty);
      await auth.refreshProfile();
      expect(auth.displayName, 'Fixture Person');
      expect(auth.photoUrl, identity['picture']);
      final count = identityRequests;
      await auth.refreshProfile();
      expect(identityRequests, count);
      await auth.close();
      auth = createAuth();
      expect(auth.displayName, 'Fixture Person');
      expect(auth.photoUrl, identity['picture']);
    },
  );

  test('missing optional claims keep old authorization usable', () async {
    identity.remove('name');
    identity.remove('picture');
    await auth.signIn(fixture.consent);
    await reloadLegacy();
    await auth.refreshProfile();
    expect(auth.connected, isTrue);
    expect(auth.displayName, isEmpty);
    expect(auth.photoUrl, isEmpty);
  });

  test(
    'old profile grants backfill and persist Drive identity without new consent',
    () async {
      identity.remove('name');
      identity.remove('picture');
      await auth.signIn(fixture.consent);
      await reloadLegacy();
      driveProfile = {
        'displayName': 'Drive Person',
        'photoLink': 'https://lh3.googleusercontent.com/drive-photo',
        'emailAddress': 'FIXTURE@example.test',
      };
      final count = driveRequests;
      await auth.refreshProfile();
      expect(driveRequests, count + 1);
      expect(auth.displayName, 'Drive Person');
      expect(auth.photoUrl, driveProfile['photoLink']);
      await auth.refreshProfile();
      expect(driveRequests, count + 1);
      await auth.close();
      auth = createAuth();
      expect(auth.displayName, 'Drive Person');
      expect(auth.photoUrl, driveProfile['photoLink']);
    },
  );

  test(
    'Drive enrichment ignores another account and preserves userinfo claims',
    () async {
      identity.remove('picture');
      await auth.signIn(fixture.consent);
      await reloadLegacy();
      driveProfile = {
        'displayName': 'Wrong Person',
        'photoLink': 'https://lh3.googleusercontent.com/wrong-photo',
        'emailAddress': 'different@example.test',
      };
      await auth.refreshProfile();
      expect(auth.displayName, 'Fixture Person');
      expect(auth.photoUrl, isEmpty);
      expect(auth.connected, isTrue);
    },
  );

  test('initial consent enriches missing profile claims from Drive', () async {
    identity.remove('name');
    identity.remove('picture');
    driveProfile = {
      'displayName': 'Drive Person',
      'photoLink': 'https://lh3.googleusercontent.com/drive-photo',
      'emailAddress': 'fixture@example.test',
    };
    await auth.signIn(fixture.consent);
    expect(auth.connected, isTrue);
    expect(auth.displayName, 'Drive Person');
    expect(auth.photoUrl, driveProfile['photoLink']);
    expect(driveRequests, 1);
  });

  test(
    'transient Drive profile failure retries while missing claims do not',
    () async {
      identity.remove('name');
      identity.remove('picture');
      await auth.signIn(fixture.consent);
      await reloadLegacy();
      driveStatus = 503;
      final count = driveRequests;
      await auth.refreshProfile();
      expect(auth.connected, isTrue);
      expect(auth.photoUrl, isEmpty);
      expect(driveRequests, count + 1);
      driveStatus = 200;
      await auth.refreshProfile();
      expect(driveRequests, count + 2);
      await auth.refreshProfile();
      expect(driveRequests, count + 2);
    },
  );

  test('profile refresh rejects an identity from another account', () async {
    await auth.signIn(fixture.consent);
    await reloadLegacy();
    identity['sub'] = 'different-account';
    await expectLater(auth.refreshProfile(), throwsStateError);
    expect(auth.account, fixture.accountSub);
    expect(auth.displayName, isEmpty);
  });

  test(
    'logout during profile refresh prevents late identity adoption',
    () async {
      await auth.signIn(fixture.consent);
      await reloadLegacy();
      identityBarrier = Completer<void>();
      final count = identityRequests;
      final pending = auth.refreshProfile();
      while (identityRequests == count) {
        await Future<void>.delayed(Duration.zero);
      }
      await auth.disconnect();
      identityBarrier!.complete();
      identityBarrier = null;
      await pending;
      expect(auth.connected, isFalse);
      expect(auth.displayName, isEmpty);
      expect(File('${root.path}/tokens.json').existsSync(), isFalse);
    },
  );
  test(
    'saved Google accounts switch and sign out independently with protected credentials',
    () async {
      await auth.close();
      final vault = MemoryProfileSecrets();
      secrets = vault;
      auth = createAuth();
      await auth.signIn(fixture.consent);
      final first = auth.account;
      identity = {
        'sub': 'second-account',
        'email': 'second@example.test',
        'name': 'Second Person',
        'picture': 'https://lh3.googleusercontent.com/second',
      };
      await auth.addAccount(fixture.consent);
      expect(auth.account, 'second-account');
      expect(auth.accounts.map((a) => a.id), ['second-account', first]);
      expect(auth.accounts.where((a) => a.current), hasLength(1));
      expect(() => auth.accounts.clear(), throwsUnsupportedError);
      expect(vault.values, hasLength(2));
      final saved = File('${root.path}/tokens.json');
      expect(saved.readAsStringSync(), isNot(contains('fixture-refresh')));
      expect(saved.statSync().mode & 0x3f, 0);
      await auth.close();
      auth = createAuth();
      expect(auth.accounts, hasLength(2));
      expect(auth.account, 'second-account');
      await auth.switchAccount(first);
      expect(auth.displayName, 'Fixture Person');
      expect(auth.email, 'fixture@example.test');
      await auth.signOutAccount('second-account');
      expect(auth.account, first);
      expect(auth.accounts, hasLength(1));
      expect(vault.values, hasLength(1));
      await auth.signOutAccount(first);
      expect(auth.accounts, isEmpty);
      expect(auth.connected, isFalse);
      expect(vault.values, isEmpty);
      expect(saved.existsSync(), isFalse);
    },
  );

  test(
    'cancelled account addition preserves the active account and its credentials',
    () async {
      await auth.signIn(fixture.consent);
      final previous = auth.accounts;
      final persisted = File('${root.path}/tokens.json').readAsStringSync();
      await expectLater(
        auth.addAccount((uri) => fixture.consent(uri, deny: true)),
        throwsStateError,
      );
      expect(auth.accounts, previous);
      expect(auth.connected, isTrue);
      expect(File('${root.path}/tokens.json').readAsStringSync(), persisted);
    },
  );

  test(
    'signing out active account selects another saved account and forget removes all',
    () async {
      await auth.signIn(fixture.consent);
      final first = auth.account;
      identity['sub'] = 'second-account';
      await auth.addAccount(fixture.consent);
      await auth.signOutAccount('second-account');
      expect(auth.account, first);
      identity['sub'] = 'third-account';
      await auth.addAccount(fixture.consent);
      await auth.forget();
      expect(auth.accounts, isEmpty);
      expect(File('${root.path}/tokens.json').existsSync(), isFalse);
      await auth.close();
      auth = createAuth();
      expect(auth.accounts, isEmpty);
    },
  );

  test(
    'adding the same account updates its saved session without duplicates',
    () async {
      await auth.signIn(fixture.consent);
      identity['name'] = 'Updated Person';
      await auth.addAccount(fixture.consent);
      expect(auth.accounts, hasLength(1));
      expect(auth.displayName, 'Updated Person');
    },
  );

  test(
    'legacy platform authorization remains usable while adding and switching accounts',
    () async {
      await auth.close();
      final vault = MemoryProfileSecrets();
      secrets = vault;
      auth = createAuth();
      await auth.signIn(fixture.consent);
      final first = auth.account;
      await auth.close();
      final file = File('${root.path}/tokens.json');
      final old = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      old.remove('refresh_token_account');
      final scopedKey = vault.values.keys.single;
      final legacyKey = scopedKey.substring(0, scopedKey.indexOf('-'));
      vault.values[legacyKey] = vault.values.remove(scopedKey)!;
      file.writeAsStringSync(jsonEncode(old));
      auth = createAuth();
      expect(auth.connected, isTrue);
      identity['sub'] = 'second-account';
      await auth.addAccount(fixture.consent);
      await auth.switchAccount(first);
      await auth.accessToken(forceRefresh: true);
      expect(vault.values.containsKey(legacyKey), isFalse);
      expect(vault.values, hasLength(2));
      expect(auth.connected, isTrue);
      expect(auth.accounts, hasLength(2));
      expect(file.readAsStringSync(), isNot(contains('fixture-refresh')));
      await auth.signOutAccount(first);
      expect(auth.account, 'second-account');
      expect(vault.values, hasLength(1));
      await auth.forget();
      expect(vault.values, isEmpty);
    },
  );

  test(
    'switching during account consent prevents late account adoption',
    () async {
      await auth.signIn(fixture.consent);
      final first = auth.account;
      identity['sub'] = 'second-account';
      await auth.addAccount(fixture.consent);
      identity['sub'] = 'third-account';
      identityBarrier = Completer<void>();
      final count = identityRequests;
      final pending = auth.addAccount(fixture.consent);
      final cancelled = expectLater(
        pending,
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.cancelled,
          ),
        ),
      );
      while (identityRequests == count) {
        await Future<void>.delayed(Duration.zero);
      }
      await auth.switchAccount(first);
      identityBarrier!.complete();
      identityBarrier = null;
      await cancelled;
      expect(auth.account, first);
      expect(auth.accounts.map((a) => a.id), isNot(contains('third-account')));
      await auth.close();
      auth = createAuth();
      expect(auth.account, first);
      expect(auth.accounts, hasLength(2));
    },
  );
}
