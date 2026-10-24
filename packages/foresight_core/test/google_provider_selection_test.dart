import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/platform_services.dart'
    show privateDirectory;
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late GoogleAuth auth;
  late GoogleFixture google;

  File clientFile(String name, String id) => File('${root.path}/$name')
    ..writeAsStringSync(
      jsonEncode({
        'installed': {'client_id': '$id.apps.googleusercontent.com'},
      }),
    );

  setUp(() async {
    root = createTestTempDirectorySync('google-provider-');
    google = GoogleFixture();
    await google.start();
    auth = GoogleAuth(
      Directory('${root.path}/auth'),
      endpoints: google.endpoints,
      defaultClient: clientFile('bundled.json', 'bundled'),
      secretStore: const UnavailableSecretStore(),
    );
    addTearDown(() async {
      await auth.close();
      await google.server.close(force: true);
    });
  });

  test(
    'failed Granola sign-in can return to direct Google after restart',
    () async {
      await auth.configureGranola();
      await expectLater(
        auth.signIn((uri) async => throw StateError('Browser unavailable')),
        throwsStateError,
      );
      expect(auth.signingIn, false);
      await auth.close();
      auth = GoogleAuth(
        auth.directory,
        endpoints: google.endpoints,
        secretStore: const UnavailableSecretStore(),
      );
      expect(auth.viaGranola, true);
      await auth.configureGoogle();
      expect(auth.viaGranola, false);
      expect(auth.client!.id, 'bundled.apps.googleusercontent.com');
      await auth.signIn((uri) async {
        expect(uri.path, '/authorize');
        expect(
          uri.queryParameters['client_id'],
          'bundled.apps.googleusercontent.com',
        );
        await google.consent(uri);
      });
      expect(auth.connected, true);
      await auth.close();
      auth = GoogleAuth(
        auth.directory,
        secretStore: const UnavailableSecretStore(),
      );
      expect(auth.viaGranola, false);
      expect(auth.connected, true);
    },
  );

  test(
    'old Granola configuration recovers using the bundled Google client',
    () async {
      // Represents a profile written before Google client preservation existed.
      await auth.close();
      final directory = auth.directory;
      privateDirectory(directory.path);
      File(
        '${directory.path}/client.json',
      ).writeAsStringSync('{"provider":"granola"}');
      auth = GoogleAuth(
        directory,
        defaultClient: File('${root.path}/bundled.json'),
        secretStore: const UnavailableSecretStore(),
      );
      final configuration = File('${directory.path}/client.json');
      final before = configuration.readAsBytesSync();
      await auth.checkGoogleClient();
      expect(auth.viaGranola, true);
      expect(configuration.readAsBytesSync(), before);
      await auth.configureGoogle();
      expect(auth.viaGranola, false);
      expect(auth.client!.id, 'bundled.apps.googleusercontent.com');
    },
  );

  test(
    'custom Google client survives repeated Granola switches and restarts',
    () async {
      await auth.configure(clientFile('custom.json', 'custom'));
      for (var attempt = 0; attempt < 2; attempt++) {
        await auth.configureGranola();
        // Retrying Granola must never replace the preserved direct client.
        await auth.configureGranola();
        await auth.close();
        auth = GoogleAuth(
          auth.directory,
          secretStore: const UnavailableSecretStore(),
        );
        await auth.configureGoogle();
        expect(auth.client!.id, 'custom.apps.googleusercontent.com');
        expect(auth.viaGranola, false);
      }
    },
  );

  test('missing Google setup leaves the Granola selection intact', () async {
    await auth.close();
    auth = GoogleAuth(
      Directory('${root.path}/without-google'),
      secretStore: const UnavailableSecretStore(),
    );
    await auth.configureGranola();
    await expectLater(auth.configureGoogle(), throwsStateError);
    expect(auth.viaGranola, true);
    expect(auth.client!.id, 'granola');
    expect(
      jsonDecode(File('${auth.directory.path}/client.json').readAsStringSync()),
      {'provider': 'granola'},
    );
  });

  test('provider changes cannot interrupt a pending Granola sign-in', () async {
    await auth.configureGranola();
    final opened = Completer<void>();
    final pending = auth.signIn((_) async => opened.complete());
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
    await opened.future;
    await expectLater(auth.configureGoogle(), throwsStateError);
    expect(auth.viaGranola, true);
    auth.cancelSignIn();
    await cancelled;
    await auth.configureGoogle();
    expect(auth.viaGranola, false);
  });
}
