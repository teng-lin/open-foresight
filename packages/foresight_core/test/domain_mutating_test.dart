import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:grpc/grpc.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/delayed_index_service.dart';
import 'package:foresight_test_support/test_paths.dart';

class HeldDelete extends DelayedIndexService {
  final deleting = Completer<void>(), deleted = Completer<void>();
  @override
  Future<DeleteResponse> deleteDocument(
    ServiceCall call,
    DeleteRequest request,
  ) async {
    if (!deleting.isCompleted) deleting.complete();
    await deleted.future;
    return DeleteResponse(success: true);
  }
}

void main() {
  test('only executing serialized helper work counts as mutating', () async {
    final temporary = createTestTempDirectorySync('mutating-');
    final service = DelayedIndexService();
    final server = Server.create(services: [service]);
    final socket = '${temporary.path}/h.sock';
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    final helper = Helper(socket, '${temporary.path}/helper');
    final store = Store('${temporary.path}/app.db');
    final domain = Domain(store, helper);
    var notifications = 0;
    domain.onBackgroundSettled = () => notifications++;
    try {
      final first = domain.index(
        store.importText('one', 'body', 'text/plain', 'fixture'),
      );
      await service.started.future;
      final second = domain.index(
        store.importText('two', 'body', 'text/plain', 'fixture'),
      );
      expect(domain.mutating, 1);
      service.release.complete();
      await Future.wait([first, second]);
      expect(domain.mutating, 0);
      expect(service.calls, 2);
      expect(notifications, 2);
      await domain.retryPendingHelperDeletes();
      expect(domain.mutating, 0);
      expect(notifications, 3);
    } finally {
      if (!service.release.isCompleted) service.release.complete();
      domain.close();
      await helper.close();
      await server.shutdown();
      store.close();
      temporary.deleteSync(recursive: true);
    }
  });
  test(
    'initialization completion is separate from the restoring latch',
    () async {
      final temporary = createTestTempDirectorySync('initializing-');
      final helper = Helper(
        '${temporary.path}/h.sock',
        '${temporary.path}/helper',
      );
      final store = Store('${temporary.path}/app.db');
      final domain = Domain(store, helper);
      final gate = Completer<void>();
      var notifications = 0;
      domain.onBackgroundSettled = () => notifications++;
      domain.initialize(gate.future);
      expect(domain.initializationPending, true);
      gate.complete();
      await gate.future;
      await Future<void>.value();
      expect(domain.initializationPending, false);
      expect(domain.restoring, true);
      expect(notifications, 1);
      domain.close();
      await helper.close();
      store.close();
      temporary.deleteSync(recursive: true);
    },
  );
  for (final pending in [false, true]) {
    test(
      '${pending ? 'pending delete retry' : 'delete'} counts only its executing helper RPC',
      () async {
        final temporary = createTestTempDirectorySync('mutating-delete-');
        final rag = HeldDelete();
        final server = Server.create(services: [rag]);
        final socket = '${temporary.path}/h.sock';
        await server.serve(
          address: InternetAddress(socket, type: InternetAddressType.unix),
          port: 0,
        );
        final helper = Helper(socket, '${temporary.path}/helper');
        final store = Store('${temporary.path}/app.db');
        final domain = Domain(store, helper);
        var settled = 0;
        domain.onBackgroundSettled = () => settled++;
        addTearDown(() async {
          if (!rag.deleted.isCompleted) rag.deleted.complete();
          domain.close();
          await helper.close();
          await server.shutdown();
          store.close();
        });
        final id = store.importText('Delete', 'body', 'text/plain', 'fixture');
        if (pending)
          store.db.execute(
            'INSERT INTO pending_helper_deletes(document_id,queued_at) VALUES(?,?)',
            [id, 0],
          );
        final work = pending
            ? domain.retryPendingHelperDeletes()
            : domain.delete(id);
        await rag.deleting.future;
        expect(domain.mutating, 1);
        rag.deleted.complete();
        await work;
        expect(domain.mutating, 0);
        expect(settled, 1);
      },
    );
  }
  test(
    'resume failure clears its completion flag before notifying background listeners',
    () async {
      final temporary = createTestTempDirectorySync('resume-failure-');
      final helper = Helper(
        '${temporary.path}/h.sock',
        '${temporary.path}/helper',
      );
      final store = Store('${temporary.path}/app.db');
      final domain = Domain(store, helper);
      final app = Application(domain);
      var notified = false;
      domain.onBackgroundSettled = () {
        if (!domain.resumeInProgress) notified = true;
      };
      domain.close();
      await expectLater(domain.resume(), throwsA(isA<StateError>()));
      expect(domain.resumeInProgress, false);
      expect(notified, true);
      expect(app.backgroundBusy, false);
      await app.close();
      await helper.close();
      store.close();
    },
  );
  test(
    'failed initialization clears pending without requiring resume',
    () async {
      final temporary = createTestTempDirectorySync('init-failure-');
      final helper = Helper(
        '${temporary.path}/h.sock',
        '${temporary.path}/helper',
      );
      final store = Store('${temporary.path}/app.db');
      final domain = Domain(store, helper);
      final app = Application(domain);
      final gate = Completer<void>();
      domain.initialize(gate.future);
      expect(app.backgroundBusy, true);
      gate.completeError(StateError('registration failed'));
      await Future<void>.value();
      await Future<void>.value();
      expect(domain.initializationPending, false);
      expect(domain.restoring, true);
      expect(app.backgroundBusy, false);
      await app.close();
      domain.close();
      await helper.close();
      store.close();
    },
  );
}
