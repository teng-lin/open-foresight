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
    if (fail) throw GrpcError.unavailable('helper offline');
    return DeleteResponse(success: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('failed helper deletes remain queued until an acknowledged retry', () async {
    final directory = Directory.systemTemp.createTempSync('purge-retry-');
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
      await domain.application.call('workspace.clear', {});
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
      await domain.application.call('workspace.clear', {});
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
      domain.close();
      await helper.close();
      await server.shutdown();
      store.close();
      directory.deleteSync(recursive: true);
    }
  });
  test('speech sweep refuses a symlinked speech root', () {
    final directory = Directory.systemTemp.createTempSync('speech-link-');
    final outside = Directory.systemTemp.createTempSync('speech-external-');
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
    final directory = Directory.systemTemp.createTempSync('speech-sweep-');
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
