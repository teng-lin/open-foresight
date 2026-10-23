import 'dart:async';
import 'dart:convert';

import 'package:foresight_core/desktop.dart' show GooglePresentation;
import 'dart:io';

import 'package:foresight_core/src/application_services/google_maintenance.dart';
import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/operation_requests.dart';
import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/persistence/meeting_queries.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class RejectingMaintenanceSecrets implements SecretStore {
  final deleted = Completer<void>();
  @override
  Future<bool> write(String key, String value) async => true;
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> delete(String key) async {
    if (!deleted.isCompleted) deleted.complete();
    throw const FileSystemException('Fixture credential deletion failed');
  }
}

void main() {
  late Directory directory;
  late Store store;
  late Helper helper;
  late GoogleFixture fixture;
  late GoogleAuth auth;
  late GoogleMaintenance maintenance;
  var changes = 0;

  setUp(() async {
    directory = createTestTempDirectorySync('google-maintenance-');
    store = Store('${directory.path}/app.db');
    helper = Helper('${directory.path}/socket', '${directory.path}/helper');
    fixture = GoogleFixture();
    await fixture.start();
    changes = 0;
    auth = GoogleAuth(
      Directory('${directory.path}/google'),
      endpoints: fixture.endpoints,
      secretStore: const UnavailableSecretStore(),
    )..client = GoogleClient('fixture.apps.googleusercontent.com', '');
    maintenance = GoogleMaintenance(
      domain: AdapterDomain(store, helper),
      auth: auth,
      meetings: MeetingQueries(store.db, supportedVersion: Store.schemaVersion),
      changed: () => changes++,
    );
    addTearDown(() async {
      await maintenance.close();
      await helper.close();
      store.close();
      await fixture.server.close(force: true);
      directory.deleteSync(recursive: true);
    });
  });

  Future<Object?> invoke(Operation operation, Map<String, dynamic> args) async {
    final handler = maintenance.handlers.singleWhere(
      (handler) => handler.operation == operation,
    );
    return handler.invoke(decodeOperationRequest(operation, args));
  }

  test('status is a pure read before explicit initialization', () async {
    final revision = store.dataRevision;
    expect(maintenance.state['connected'], isFalse);
    expect(maintenance.state['lastRefresh'], 0);
    expect(await invoke(Operation.googleStatus, {}), maintenance.state);
    expect(store.dataRevision, revision);
    expect(changes, 0);
    expect(() => maintenance.connections, throwsStateError);
    maintenance.initialize();
    final connection = maintenance.connections;
    maintenance.initialize();
    expect(maintenance.connections, same(connection));
  });

  test(
    'typed Drive query preserves parent, filter and modification date',
    () async {
      maintenance.initialize();
      await auth.signIn(fixture.consent);
      final google = GooglePresentation.fromWire(
        jsonDecode(jsonEncode(await invoke(Operation.googleStatus, {}))),
      );
      expect(google.connected, isTrue);
      expect(google.configured, isTrue);
      expect(google.account, 'fixture-account');
      expect(google.email, 'fixture@example.test');
      expect(google.accounts.single.id, 'fixture-account');
      expect(google.accounts.single.email, 'fixture@example.test');
      expect(google.accounts.single.current, isTrue);
      final result = await invoke(Operation.googleDriveFiles, {
        'parent': 'nested',
        'query': 'Apollo',
        'modifiedAfter': '2020-01-02T03:04:05Z',
      });
      expect(result, isA<List>());
      final query = fixture.queries.last;
      expect(query, contains("'nested' in parents"));
      expect(query, contains('Apollo'));
      expect(query, contains('2020-01-02T03:04:05.000Z'));
    },
  );

  test(
    'sign-in ownership survives peer cancellation and drains on owner cancel',
    () async {
      maintenance.initialize();
      final first = StreamIterator(maintenance.signIn('first'));
      expect(await first.moveNext(), isTrue);
      expect(first.current, contains('authorization_url'));
      await expectLater(
        maintenance.signIn('peer').first,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      maintenance.cancelSignIn('peer');
      expect(auth.signingIn, isTrue);
      maintenance.cancelSignIn('first');
      await expectLater(
        first.moveNext(),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await first.cancel();
      final next = StreamIterator(maintenance.signIn('next'));
      expect(await next.moveNext(), isTrue);
      maintenance.cancelSignIn('next');
      await expectLater(next.moveNext(), throwsA(isA<RpcError>()));
      await next.cancel();
      expect(auth.signingIn, isFalse);
    },
  );

  test(
    'workspace cleanup observes credential errors without holding local work',
    () async {
      await maintenance.close();
      final secrets = RejectingMaintenanceSecrets();
      auth = GoogleAuth(
        Directory('${directory.path}/cleanup-google'),
        secretStore: secrets,
      );
      maintenance = GoogleMaintenance(
        domain: AdapterDomain(store, helper),
        auth: auth,
        meetings: MeetingQueries(
          store.db,
          supportedVersion: Store.schemaVersion,
        ),
        changed: () => changes++,
      )..initialize();
      final oldConnection = maintenance.connections;
      maintenance.forgetWorkspaceAccounts();
      expect(maintenance.connections, isNot(same(oldConnection)));
      await secrets.deleted.future;
      await Future<void>.delayed(Duration.zero);
      expect(maintenance.state['loadError'], contains('cleanup failed'));
      expect(changes, greaterThan(0));
      await maintenance.close();
      await maintenance.close();
    },
  );
}
