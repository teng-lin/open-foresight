import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';

import '../test_support/core_fixture.dart';
import 'desktop_connection_fixture.dart';

class _OfflineHelper extends Helper {
  _OfflineHelper(super.socket, super.storage);
  @override
  Future<void> start() async => state = 'disconnected';
}

class _HeldDomain extends CommandFixtureDomain {
  _HeldDomain(super.store, super.helper);
  final entered = <Map<String, dynamic>>[];
  final holds = <String, Completer<void>>{};
  final failures = <String, Object>{};

  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    expect(operation, Operation.meetingsCreate);
    final title = args['title'] as String;
    entered.add(Map.of(args));
    await holds[title]?.future;
    if (failures[title] case final failure?) throw failure;
    return super.command(operation, args);
  }
}

class _HeldConnection extends TestDesktopConnection {
  _HeldConnection(super.application);
  final entered = <String>[];
  final holds = <String, Completer<void>>{};

  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    final title = args['title'] as String;
    entered.add(title);
    await holds[title]?.future;
    return super.command(operation, args);
  }
}

Matcher _rpc(RpcErrorCode code) =>
    isA<RpcError>().having((error) => error.code, 'code', code);

void main() {
  late Directory root;
  late Store store;
  late _HeldDomain domain;
  late _HeldConnection connection;

  setUp(() {
    root = createTestTempDirectorySync('guarded-dispatch-');
    store = Store('${root.path}/application.db');
    domain = _HeldDomain(
      store,
      _OfflineHelper('${root.path}/socket', '${root.path}/helper'),
    );
    connection = _HeldConnection(Application(domain));
    addTearDown(() async {
      for (final hold in [...connection.holds.values, ...domain.holds.values]) {
        if (!hold.isCompleted) hold.complete();
      }
      connection.close();
      await connection.closed;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
  });

  test(
    'guarded dispatch keeps a held domain override and its failure',
    () async {
      final held = domain.holds['held'] = Completer<void>();
      final failure = StateError('Fixture create rejected');
      domain.failures['held'] = failure;
      final work = connection.commandCurrent(Operation.meetingsCreate, {
        'title': 'held',
        'idempotency_key': 'held-key',
      }, () => true);
      final rejected = expectLater(work, throwsA(same(failure)));
      await Future<void>(() {});
      expect(connection.entered, ['held']);
      expect(domain.entered.single['title'], 'held');
      expect(store.rows('SELECT id FROM meetings'), isEmpty);
      held.complete();
      await rejected;
      expect(store.rows('SELECT id FROM meetings'), isEmpty);
    },
  );

  test(
    'concurrent held guards stay independent through both overrides',
    () async {
      var firstCurrent = true;
      final firstConnection = connection.holds['first'] = Completer<void>();
      final secondConnection = connection.holds['second'] = Completer<void>();
      final firstDomain = domain.holds['first'] = Completer<void>();
      final secondDomain = domain.holds['second'] = Completer<void>();
      final first = connection.commandCurrent(Operation.meetingsCreate, {
        'title': 'first',
        'idempotency_key': 'first-key',
      }, () => firstCurrent);
      final cancelled = expectLater(
        first,
        throwsA(_rpc(RpcErrorCode.cancelled)),
      );
      final second = connection.commandCurrent(Operation.meetingsCreate, {
        'title': 'second',
        'idempotency_key': 'second-key',
      }, () => true);
      expect(connection.entered, ['first', 'second']);
      expect(domain.entered, isEmpty);
      firstCurrent = false;
      // Settle in the opposite order to admission, keeping both zones alive.
      secondConnection.complete();
      firstConnection.complete();
      await Future<void>(() {});
      expect(domain.entered.map((args) => args['title']), ['second', 'first']);
      secondDomain.complete();
      expect(await second, isA<Map>());
      firstDomain.complete();
      await cancelled;
      // A later unguarded call must not inherit either request's predicate.
      await connection.command(Operation.meetingsCreate, {'title': 'ordinary'});
      expect(
        store
            .rows('SELECT title FROM meetings ORDER BY id')
            .map((row) => row['title']),
        ['second', 'ordinary'],
      );
    },
  );

  test(
    'held dispatch retains its original workspace envelope after adoption',
    () async {
      final epoch = connection.workspaceEpoch;
      final connectionHeld = connection.holds['old workspace'] =
          Completer<void>();
      final held = domain.holds['old workspace'] = Completer<void>();
      final work = connection.commandCurrent(Operation.meetingsCreate, {
        'title': 'old workspace',
        'idempotency_key': 'old-key',
      }, () => true);
      final rejected = expectLater(work, throwsA(_rpc(RpcErrorCode.notFound)));
      await Future<void>(() {});
      expect(domain.entered, isEmpty);
      store.renewWorkspaceEpoch();
      connection.adoptWorkspace();
      expect(connection.workspaceEpoch, isNot(epoch));
      connectionHeld.complete();
      await Future<void>(() {});
      expect(domain.entered.single['workspace_epoch'], epoch);
      held.complete();
      await rejected;
      expect(store.rows('SELECT id FROM meetings'), isEmpty);
    },
  );

  test('plain domain dispatch also checks the caller predicate', () async {
    final plainRoot = createTestTempDirectorySync('plain-dispatch-');
    final plainStore = Store('${plainRoot.path}/application.db');
    final plain = TestDesktopConnection(
      Application(
        Domain(
          plainStore,
          _OfflineHelper(
            '${plainRoot.path}/socket',
            '${plainRoot.path}/helper',
          ),
        ),
      ),
    );
    try {
      await expectLater(
        plain.commandCurrent(Operation.meetingsCreate, {
          'title': 'cancelled',
        }, () => false),
        throwsA(_rpc(RpcErrorCode.cancelled)),
      );
      expect(plainStore.rows('SELECT id FROM meetings'), isEmpty);
    } finally {
      plain.close();
      await plain.closed;
      if (plainRoot.existsSync()) plainRoot.deleteSync(recursive: true);
    }
  });
}
