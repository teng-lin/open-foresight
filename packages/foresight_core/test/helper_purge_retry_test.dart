import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'dart:async';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class PurgeService extends RagServiceBase {
  bool fail = true;
  String? invalidDocument;
  final requested = <String>[];
  final indexed = <String>[];
  Completer<void>? deleteGate, deleteEntered;
  @override
  Future<IndexResponse> indexDocument(
    ServiceCall call,
    IndexRequest request,
  ) async {
    indexed.add(request.documentId);
    return IndexResponse(success: true);
  }

  @override
  Future<DeleteResponse> deleteDocument(
    ServiceCall call,
    DeleteRequest request,
  ) async {
    requested.add(request.documentId);
    final gate = deleteGate;
    if (gate != null) {
      if (!deleteEntered!.isCompleted) deleteEntered!.complete();
      await gate.future;
    }
    if (request.documentId == invalidDocument) {
      throw GrpcError.invalidArgument('invalid document');
    }
    if (fail) throw GrpcError.unavailable('helper offline');
    return DeleteResponse(success: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final interruption in [
    'closed',
    'disposed',
    'cleared',
    'closed after document error',
  ]) {
    test('late helper delete keeps its durable queue when $interruption', () async {
      final directory = createTestTempDirectorySync('purge-interrupted-');
      final path = '${directory.path}/app.db';
      var store = Store(path);
      final service = PurgeService()
        ..fail = false
        ..deleteGate = Completer<void>()
        ..deleteEntered = Completer<void>();
      final server = Server.create(services: [service]);
      final socket = '${directory.path}/helper.sock';
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final helper = Helper(
        socket,
        '${directory.path}/helper',
        manageProcess: false,
      );
      final domain = Domain(store, helper);
      Domain? replacement;
      try {
        store.db.execute(
          "INSERT INTO pending_helper_deletes(document_id,queued_at) "
          "VALUES('first',1),('second',1)",
        );
        final retry = domain.retryPendingHelperDeletes();
        await service.deleteEntered!.future;
        if (interruption == 'cleared') {
          domain.invalidateWorkspace();
          // A later clear can queue the same document ID for a new workspace.
          store.db.execute(
            "UPDATE pending_helper_deletes SET queued_at=2 WHERE document_id='first'",
          );
        } else {
          domain.close();
        }
        if (interruption == 'disposed') {
          store.close();
          store = Store(path);
        }
        if (interruption == 'closed after document error') {
          service.invalidDocument = 'first';
        }
        service.deleteGate!.complete();
        await retry;
        expect(service.requested, ['first']);
        expect(
          store.rows(
            'SELECT document_id,queued_at FROM pending_helper_deletes ORDER BY document_id',
          ),
          [
            {
              'document_id': 'first',
              'queued_at': interruption == 'cleared' ? 2 : 1,
            },
            {'document_id': 'second', 'queued_at': 1},
          ],
        );
        expect(domain.mutating, 0);
        domain.close();
        store.close();
        store = Store(path);
        service.deleteGate = null;
        service.invalidDocument = null;
        replacement = Domain(store, helper);
        await replacement.retryPendingHelperDeletes();
        expect(store.rows('SELECT * FROM pending_helper_deletes'), isEmpty);
        expect(service.requested, ['first', 'first', 'second']);
      } finally {
        final gate = service.deleteGate;
        if (gate != null && !gate.isCompleted) gate.complete();
        domain.close();
        replacement?.close();
        await helper.close();
        await server.shutdown();
        store.close();
      }
    });
  }

  test('failed helper deletes remain queued until an acknowledged retry', () async {
    final directory = createTestTempDirectorySync('purge-retry-');
    final store = Store('${directory.path}/app.db');
    final service = PurgeService();
    final server = Server.create(services: [service]);
    final socket = '${directory.path}/helper.sock';
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    final helper = Helper(
      socket,
      '${directory.path}/helper',
      manageProcess: false,
    );
    final domain = Domain(store, helper);
    final app = Application(domain);
    try {
      store.importText(
        'Deleted secret',
        'private',
        'text/plain',
        'fixture',
        id: 'old-document',
      );
      store.db.execute(
        "UPDATE sources SET deleted=1,state='delete_failed' WHERE id='old-document'",
      );
      await app.call('workspace.clear', {});
      await domain.retryPendingHelperDeletes();
      expect(store.rows('SELECT * FROM pending_helper_deletes'), hasLength(1));
      service.fail = false;
      await domain
          .resume(); // The helper readiness/reconnect callback invokes resume.
      expect(store.rows('SELECT * FROM pending_helper_deletes'), isEmpty);
      expect(service.requested, everyElement('old-document'));
      expect(service.requested.length, greaterThanOrEqualTo(2));
      store.importText(
        'Replacement',
        'stale captured body',
        'text/plain',
        'fixture',
        id: 'old-document',
      );
      store.db.execute('INSERT INTO pending_helper_deletes VALUES(?,?)', [
        'old-document',
        124,
      ]);
      service.deleteGate = Completer<void>();
      service.deleteEntered = Completer<void>();
      final indexing = domain.index('old-document');
      final cancelled = expectLater(indexing, throwsA(isA<RpcError>()));
      await service.deleteEntered!.future;
      await app.call('workspace.clear', {});
      service.deleteGate!.complete();
      await cancelled;
      await domain.retryPendingHelperDeletes();
      expect(
        service.indexed,
        isEmpty,
        reason:
            'A clear during the delete preflight must not republish captured source content',
      );
      expect(store.sources, isEmpty);
    } finally {
      await app.close();
      domain.close();
      await helper.close();
      await server.shutdown();
      store.close();
      directory.deleteSync(recursive: true);
    }
  });
  for (final unresponsive in [false, true]) {
    test(
      'transport failure bounds retries (unresponsive=$unresponsive)',
      () async {
        final directory = createTestTempDirectorySync('purge-bound-');
        final store = Store('${directory.path}/app.db');
        final service = PurgeService();
        final server = Server.create(services: [service]);
        final socket = '${directory.path}/helper.sock';
        await server.serve(
          address: InternetAddress(socket, type: InternetAddressType.unix),
          port: 0,
        );
        final helper = Helper(
          socket,
          '${directory.path}/helper',
          manageProcess: false,
        );
        final domain = Domain(store, helper);
        final app = Application(domain);
        try {
          for (final id in ['first', 'second', 'third']) {
            store.db.execute('INSERT INTO pending_helper_deletes VALUES(?,?)', [
              id,
              1,
            ]);
          }
          if (unresponsive) {
            service.deleteGate = Completer<void>();
            service.deleteEntered = Completer<void>();
          }
          // The entire serialized pass takes at most one five-second deadline.
          await domain.retryPendingHelperDeletes().timeout(
            const Duration(seconds: 8),
          );
          expect(service.requested, ['first']);
          expect(
            store.rows('SELECT * FROM pending_helper_deletes'),
            hasLength(3),
          );
          service.deleteGate?.complete();
          service.deleteGate = null;
          service.fail = false;
          service.invalidDocument = 'first';
          await domain.retryPendingHelperDeletes();
          expect(store.rows('SELECT document_id FROM pending_helper_deletes'), [
            {'document_id': 'first'},
          ]);
          expect(service.requested, ['first', 'first', 'second', 'third']);
          service.invalidDocument = null;
          await domain.retryPendingHelperDeletes();
          expect(store.rows('SELECT * FROM pending_helper_deletes'), isEmpty);
        } finally {
          await app.close();
          domain.close();
          await helper.close();
          await server.shutdown();
          store.close();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }

  test('speech sweep refuses a symlinked speech root', () {
    final directory = createTestTempDirectorySync('speech-link-');
    final outside = createTestTempDirectorySync('speech-external-');
    try {
      final audio = File('${outside.path}/foresight-asr-external.wav')
        ..writeAsStringSync('external');
      Link('${directory.path}/speech').createSync(outside.path);
      sweepStaleSpeechAudio(directory.path);
      expect(audio.existsSync(), isTrue);
    } finally {
      directory.deleteSync(recursive: true);
      outside.deleteSync(recursive: true);
    }
  });

  test('speech sweep removes stale WAVs and preserves unrelated files', () {
    final directory = createTestTempDirectorySync('speech-sweep-');
    try {
      final speech = Directory('${directory.path}/speech')..createSync();
      final stale = File('${speech.path}/foresight-asr-old.wav')
        ..writeAsStringSync('private audio');
      final retained = File('${speech.path}/model.bin')
        ..writeAsStringSync('retained');
      sweepStaleSpeechAudio(directory.path);
      expect(stale.existsSync(), isFalse);
      expect(retained.existsSync(), isTrue);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}
