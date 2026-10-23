import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';

import 'desktop_connection_fixture.dart';
import 'store_reader_fixture.dart';
import '../test_support/reader_admissions.dart';
import 'package:foresight_core/desktop.dart' show StoreReadQueries, StoreReader;
import 'package:foresight_core/src/sqlite_store_reader.dart';
import 'package:foresight_core/src/sqlite_read_session.dart';
import 'package:foresight_core/src/read_coordinator.dart';

class ReadinessHelper extends Helper {
  ReadinessHelper(super.socket, super.storage, this.ready);
  final bool ready;
  @override
  Future<void> start() async {
    state = ready ? 'live' : 'disconnected';
    if (ready) await onReady?.call();
  }
}

class ResumeDomain extends Domain {
  ResumeDomain(super.store, super.helper);
  int resumes = 0;
  @override
  Future<void> resume() async => resumes++;
}

class _CustomReaderConnection extends TestDesktopConnection {
  _CustomReaderConnection(super.application, this.reader);
  final StoreReader reader;
  @override
  StoreReader get store => reader;
}

class _ReaderWorker implements ReadWorker {
  _ReaderWorker(Store store) : session = SqliteReadSession.borrow(store);
  final SqliteReadSession session;
  int reads = 0;
  @override
  Future<ReadWorkerReply> read(ReadWorkerRequest request) async {
    reads++;
    return session.query(request.projection, request.arguments);
  }

  @override
  Future<void> close() async => session.close();
}

void main() {
  test(
    'fixture refreshes watched rows only when durable identity changes',
    () async {
      final root = createTestTempDirectorySync('fixture-watch-');
      final store = Store('${root.path}/application.db');
      final admissions = ReaderAdmissions();
      fixtureReader(store, admissions: admissions);
      final helper = ReadinessHelper(
        '${root.path}/socket',
        '${root.path}/helper',
        true,
      );
      final connection = TestDesktopConnection(
        Application(Domain(store, helper)),
      );
      final values = StreamIterator(
        connection.store.watch(StoreReadQueries.preference('fixture')),
      );
      try {
        expect(await values.moveNext(), isTrue);
        expect(values.current.value, '');
        // The result is emitted before the coordinator settles its worker.
        await Future<void>.delayed(Duration.zero);
        expect(admissions.workers['preference'], 1);
        helper.changed?.call();
        expect(
          admissions.workers['preference'],
          1,
          reason: 'Status-only events retain prepared queries',
        );
        store.setPreference('fixture', 'saved');
        helper.changed?.call();
        expect(
          admissions.workers['preference'],
          2,
          reason: 'Durable change starts the refresh',
        );
        expect(await values.moveNext(), isTrue);
        expect(values.current.value, 'saved');
        expect(admissions.workers['preference'], 2);
        helper.changed?.call();
        expect(admissions.workers['preference'], 2);
      } finally {
        await values.cancel();
        connection.close();
        await connection.closed;
        root.deleteSync(recursive: true);
      }
    },
  );

  test(
    'durable events invalidate the overridden reader, not the writer reader',
    () async {
      final root = createTestTempDirectorySync('fixture-custom-');
      final store = Store('${root.path}/application.db');
      final worker = _ReaderWorker(store);
      final reader = SqliteStoreReader.borrow(store, worker: worker);
      final helper = ReadinessHelper(
        '${root.path}/socket',
        '${root.path}/helper',
        true,
      );
      final connection = _CustomReaderConnection(
        Application(Domain(store, helper)),
        reader,
      );
      final values = StreamIterator(
        reader.watch(StoreReadQueries.preference('fixture')),
      );
      try {
        expect(await values.moveNext(), isTrue);
        expect(values.current.value, '');
        await Future<void>.delayed(Duration.zero);
        expect(worker.reads, 1);
        helper.changed?.call();
        await Future<void>.delayed(Duration.zero);
        expect(worker.reads, 1, reason: 'Status-only events do not refresh');
        store.setPreference('fixture', 'custom');
        helper.changed?.call();
        expect(worker.reads, 2, reason: 'The overridden reader refreshes');
        expect(await values.moveNext(), isTrue);
        expect(values.current.value, 'custom');
        await Future<void>.delayed(Duration.zero);
        expect(worker.reads, 2);
        helper.changed?.call();
        await Future<void>.delayed(Duration.zero);
        expect(worker.reads, 2);
      } finally {
        await values.cancel();
        await reader.close();
        connection.close();
        await connection.closed;
      }
    },
  );

  for (final ready in [false, true]) {
    test('fixture initializes only after helper readiness ($ready)', () async {
      final Directory directory = createTestTempDirectorySync('fixture-ready-');
      final domain = ResumeDomain(
        Store('${directory.path}/application.db'),
        ReadinessHelper(
          '${directory.path}/socket',
          '${directory.path}/helper',
          ready,
        ),
      );
      final connection = TestDesktopConnection(Application(domain));
      final initialSession = connection.clientSessionGeneration;
      try {
        final initialization = connection.initialize();
        expect(connection.initialize(), same(initialization));
        if (!ready) {
          var initialized = false;
          unawaited(initialization.then((_) => initialized = true));
          await Future<void>.delayed(Duration.zero);
          expect(initialized, isFalse);
          expect(domain.resumes, 0);
          // A later owner readiness notification admits the pending initializer.
          await domain.helper.onReady!();
        }
        await initialization;
        await connection.resume();
        expect(domain.resumes, 1);
        expect(connection.clientSessionGeneration, same(initialSession));
        final observed = <Object>[];
        final changes = connection.changes.listen((_) {
          observed.add(connection.clientSessionGeneration);
        });
        domain.helper.changed?.call();
        expect(observed, [same(initialSession)]);
        connection.replaceClientSessionForTesting();
        final replacement = connection.clientSessionGeneration;
        expect(replacement, isNot(same(initialSession)));
        expect(observed, [same(initialSession), same(replacement)]);
        domain.helper.changed?.call();
        expect(observed.last, same(replacement));
        await changes.cancel();
      } finally {
        connection.close();
        await connection.closed;
        directory.deleteSync(recursive: true);
      }
    });
  }
  test('closing settles an initializer waiting for helper readiness', () async {
    final directory = createTestTempDirectorySync('fixture-ready-close-');
    final domain = ResumeDomain(
      Store('${directory.path}/application.db'),
      ReadinessHelper(
        '${directory.path}/socket',
        '${directory.path}/helper',
        false,
      ),
    );
    final connection = TestDesktopConnection(Application(domain));
    final initialization = connection.initialize();
    final rejected = expectLater(
      initialization,
      throwsA(
        isA<RpcError>().having(
          (error) => error.code,
          'code',
          RpcErrorCode.cancelled,
        ),
      ),
    );
    connection.close();
    await connection.closed;
    await rejected;
    expect(domain.resumes, 0);
    directory.deleteSync(recursive: true);
  });
}
