import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';
import 'helper_adoption_test.dart' show AdoptionRag, AdoptionControl;

class RecoveryRag extends AdoptionRag {
  final indexed = Completer<IndexRequest>();
  final deleted = <String>[];
  @override
  Future<IndexResponse> indexDocument(
    ServiceCall call,
    IndexRequest request,
  ) async {
    if (!indexed.isCompleted) indexed.complete(request);
    return IndexResponse(success: true);
  }

  @override
  Future<DeleteResponse> deleteDocument(
    ServiceCall call,
    DeleteRequest request,
  ) async {
    deleted.add(request.documentId);
    return DeleteResponse(success: true);
  }
}

void main() {
  test(
    'startup sweeps audio, drains helper purges and indexes interrupted transcript',
    () async {
      final original = Map.of(runtimeConfiguration.environment);
      for (final key in [
        'FORESIGHT_HELPER',
        'FORESIGHT_NATIVE',
        'FORESIGHT_RUNTIME_REVISION',
        'FORESIGHT_INSTALL_ROOT',
      ]) {
        runtimeConfiguration.environment.remove(key);
      }
      final root = createTestTempDirectorySync('of-recovery-');
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
      privateDirectory(profile.data);
      privateDirectory(profile.runtime);
      final store = Store('${profile.data}/application.db');
      final meeting = store.meeting('Interrupted');
      store.transcript(
        meeting,
        'Unindexed final transcript',
        true,
        0,
        100,
        'imported',
      );
      store.db.execute("UPDATE meetings SET state='recording' WHERE id=?", [
        meeting,
      ]);
      store.db.execute('INSERT INTO pending_helper_deletes VALUES(?,?)', [
        'cleared-secret',
        123,
      ]);
      store.close();
      final speech = Directory('${profile.data}/speech')..createSync();
      final wav = File('${speech.path}/foresight-asr-stale.wav')
        ..writeAsStringSync('secret');
      final rag = RecoveryRag();
      final server = Server.create(
        services: [
          rag,
          AdoptionControl(control.State(pipeline: 'ready')),
        ],
      );
      await server.serve(
        address: InternetAddress(
          '${profile.runtime}/helper.sock',
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      ApplicationService? service;
      try {
        service = await ApplicationService.start(profile);
        expect(wav.existsSync(), isFalse);
        final request = await rag.indexed.future.timeout(
          const Duration(seconds: 5),
        );
        expect(request.content, contains('Unindexed final transcript'));
        expect(request.documentId, 'meeting-$meeting');
        await eventually(
          () => service!.domain.store.sources.any(
            (row) =>
                row['id'] == 'meeting-$meeting' && row['state'] == 'indexed',
          ),
        );
        expect(rag.deleted, contains('cleared-secret'));
        expect(
          service.domain.store.rows('SELECT * FROM pending_helper_deletes'),
          isEmpty,
        );
        expect(
          service.domain.store
              .rows('SELECT state FROM meetings')
              .single['state'],
          'interrupted',
        );
      } finally {
        await service?.close();
        await server.shutdown();
        root.deleteSync(recursive: true);
        runtimeConfiguration.environment
          ..clear()
          ..addAll(original);
      }
    },
  );

  for (final adopted in [false, true]) {
    test('failed startup ${adopted ? 'keeps an adopted' : 'removes its own'} '
        'endpoint record before releasing ownership', () async {
      final original = Map.of(runtimeConfiguration.environment);
      for (final key in [
        'FORESIGHT_HELPER',
        'FORESIGHT_NATIVE',
        'FORESIGHT_RUNTIME_REVISION',
        'FORESIGHT_INSTALL_ROOT',
      ]) {
        runtimeConfiguration.environment.remove(key);
      }
      final root = createTestTempDirectorySync('of-failed-start-');
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
      try {
        privateDirectory(profile.data);
        privateDirectory(profile.runtime);
        final record = File('${profile.data}/.application-endpoint.json');
        if (adopted) {
          // An unclean predecessor's record names the runtime to adopt.
          record.writeAsStringSync(
            jsonEncode({'data': profile.data, 'runtime': profile.runtime}),
          );
        }
        // The desktop capability check fails after the record is published.
        final capability = Link('${profile.data}/.desktop-capability')
          ..createSync('${root.path}/elsewhere');
        await expectLater(
          ApplicationService.start(profile),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('Desktop capability must not be a symbolic link'),
            ),
          ),
        );
        expect(record.existsSync(), adopted);
        // Ownership was released: a corrected start acquires it.
        capability.deleteSync();
        final service = await ApplicationService.start(profile);
        await service.close();
      } finally {
        runtimeConfiguration.environment
          ..clear()
          ..addAll(original);
        root.deleteSync(recursive: true);
      }
    });
  }
}
