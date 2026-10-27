import 'sql_support_test_bootstrap.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'dart:async';
import 'dart:io';
import 'package:grpc/grpc.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/delayed_index_service.dart';
import 'package:foresight_test_support/transcript_index_service.dart';
import 'package:foresight_test_support/test_recording.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:test/test.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';

class PausingDomain extends Domain {
  PausingDomain(super.store, super.helper);
  int waits = 0;
  int? pauseAt;
  final paused = Completer<void>();
  @override
  Future<void> waitForSourceWork({bool Function()? current}) {
    waits++;
    if (waits == pauseAt) {
      pauseSources();
      if (!paused.isCompleted) paused.complete();
    }
    return super.waitForSourceWork(current: current);
  }
}

class HeldStopRecording extends TestRecording {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> stop() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    await super.stop();
  }
}

class CloseQueueService extends DelayedIndexService {
  int deletions = 0;
  @override
  Future<DeleteResponse> deleteDocument(
    ServiceCall call,
    DeleteRequest request,
  ) async {
    deletions++;
    return DeleteResponse(success: true);
  }
}

void main() {
  bootstrapSqlSupportFixture();
  test(
    'close refuses queued deletes before RPC and joins held index cancellation',
    () async {
      final temporary = createTestTempDirectorySync('closed-queue-');
      final peer = CloseQueueService();
      final server = Server.create(services: [peer]);
      final socket = '${temporary.path}/h.sock';
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final helper = Helper(
        socket,
        '${temporary.path}/helper',
        manageProcess: false,
      );
      final store = Store('${temporary.path}/app.db');
      final domain = Domain(store, helper);
      addTearDown(() async {
        if (!peer.release.isCompleted) peer.release.complete();
        domain.close();
        await domain.drain();
        await helper.close();
        await server.shutdown();
        store.close();
        temporary.deleteSync(recursive: true);
      });
      final first = store.importText(
        'Held index',
        'body',
        'text/plain',
        'fixture',
      );
      final deleted = store.importText(
        'Queued delete',
        'body',
        'text/plain',
        'fixture',
      );
      store.db.execute('INSERT INTO pending_helper_deletes VALUES(?,?)', [
        'older-purge',
        1,
      ]);
      final indexing = expectLater(
        domain.index(first),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await peer.started.future.timeout(const Duration(seconds: 5));
      final deletion = expectLater(
        domain.delete(deleted),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      final retry = expectLater(
        domain.retryPendingHelperDeletes(),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      domain.close();
      await domain.drain().timeout(const Duration(seconds: 5));
      await Future.wait([indexing, deletion, retry]);
      expect(peer.calls, 1);
      expect(peer.deletions, 0);
      expect(
        store.sourceById(deleted, includeDeleted: true).single['deleted'],
        1,
      );
      expect(
        store.rows('SELECT * FROM pending_helper_deletes WHERE document_id=?', [
          'older-purge',
        ]),
        hasLength(1),
      );
      expect(domain.mutating, 0);
      expect(domain.cancellationWatchCount, 0);
    },
  );

  test(
    'cancelled parked index settles and leaves durable pending source',
    () async {
      final temporary = createTestTempDirectorySync('cancel-source-');
      final helper = Helper(
        '${temporary.path}/h.sock',
        '${temporary.path}/helper',
      );
      final store = Store('${temporary.path}/app.db');
      final domain = Domain(store, helper)..pauseSources();
      final id = store.importText('one', 'body', 'text/plain', 'fixture');
      var current = true;
      final work = domain.index(id, current: () => current);
      final cancelled = expectLater(
        work,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await Future<void>.value();
      expect(domain.cancellationWatchCount, 1);
      current = false;
      domain.checkCancellations();
      await cancelled;
      expect(domain.cancellationWatchCount, 0);
      expect(
        store.rows('SELECT state FROM sources WHERE id=?', [
          id,
        ]).single['state'],
        'pending',
      );
      domain.close();
      await helper.close();
      store.close();
      temporary.deleteSync(recursive: true);
    },
  );
  for (final kind in ['file', 'url']) {
    for (final suppliedCurrent in [false, true]) {
      test(
        '$kind refresh indexes its advanced revision after a pause, current=$suppliedCurrent',
        () async {
          final temporary = createTestTempDirectorySync('refresh-current-');
          final rag = DelayedIndexService()..release.complete();
          final server = Server.create(services: [rag]);
          final socket = '${temporary.path}/h.sock';
          await server.serve(
            address: InternetAddress(socket, type: InternetAddressType.unix),
            port: 0,
          );
          final helper = Helper(socket, '${temporary.path}/helper');
          final store = Store('${temporary.path}/app.db');
          final domain = PausingDomain(store, helper);
          final app = Application(domain);
          HttpServer? web;
          addTearDown(() async {
            await app.close();
            domain.close();
            await helper.close();
            await server.shutdown();
            await web?.close(force: true);
            store.close();
          });
          String uri;
          if (kind == 'file') {
            final file = File('${temporary.path}/file.txt')
              ..writeAsStringSync('new revision');
            uri = file.uri.toString();
            domain.pauseAt =
                2; // pre-publication wait, then production Domain.index.
          } else {
            web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            web.listen((request) async {
              domain.pauseSources();
              if (!domain.paused.isCompleted) domain.paused.complete();
              request.response
                ..headers.contentType = ContentType.html
                ..write(
                  '<html><body><p>New remote revision with useful material.</p></body></html>',
                );
              await request.response.close();
            });
            uri = 'http://127.0.0.1:${web.port}/page';
          }
          final id = store.importText(
            'old',
            'old body',
            'text/plain',
            kind == 'file' ? 'file fixture' : 'url:$uri',
            sourceUri: uri,
          );
          final work = app.reimport(
            current: suppliedCurrent ? () => true : null,
            allowPrivateNetwork: true,
          );
          await domain.paused.future;
          await eventually(
            () =>
                store.sources.single['revision'] != 1 &&
                domain.cancellationWatchCount == 1,
          );
          expect(store.sources.single['state'], 'pending');
          expect(domain.mutating, 0);
          domain.resumeSources();
          await work;
          expect(store.sources.single['id'], id);
          expect(store.sources.single['state'], 'indexed');
          expect(rag.calls, 1);
          expect(domain.cancellationWatchCount, 0);
        },
      );
    }
  }
  test(
    'cancelled file refresh settles while post-publication index is parked',
    () async {
      final temporary = createTestTempDirectorySync('refresh-cancel-');
      final helper = Helper(
        '${temporary.path}/h.sock',
        '${temporary.path}/helper',
      );
      final store = Store('${temporary.path}/app.db');
      final domain = PausingDomain(store, helper)..pauseAt = 2;
      final app = Application(domain);
      addTearDown(() async {
        await app.close();
        domain.close();
        await helper.close();
        store.close();
      });
      final file = File('${temporary.path}/file.txt')
        ..writeAsStringSync('updated');
      store.importText(
        'old',
        'old body',
        'text/plain',
        'fixture',
        sourceUri: file.uri.toString(),
      );
      var current = true;
      final work = app.call('sources.refresh', {}, current: () => current);
      final cancelled = expectLater(
        work,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await domain.paused.future;
      await eventually(() => domain.cancellationWatchCount == 1);
      current = false;
      domain.checkCancellations();
      await cancelled;
      expect(domain.cancellationWatchCount, 0);
      expect(store.sources.single['state'], 'pending');
    },
  );
  test('workspace clear cancels an index parked on paused sources', () async {
    final temporary = createTestTempDirectorySync('clear-cancel-');
    final helper = Helper(
      '${temporary.path}/h.sock',
      '${temporary.path}/helper',
    );
    final store = Store('${temporary.path}/app.db');
    final domain = Domain(store, helper)..pauseSources();
    final app = Application(domain);
    addTearDown(() async {
      await app.close();
      domain.close();
      await helper.close();
      store.close();
    });
    final id = store.importText('old', 'body', 'text/plain', 'fixture');
    final work = app.call('sources.index', {'id': id});
    final cancelled = expectLater(
      work,
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
      ),
    );
    await eventually(() => domain.cancellationWatchCount == 1);
    await app.call('workspace.clear', {});
    await cancelled;
    expect(domain.cancellationWatchCount, 0);
  });
  test(
    'one cancelled Stop waiter leaves capture drain shared and indexing separate',
    () async {
      final temporary = createTestTempDirectorySync('stop-cancel-');
      final rag = DelayedIndexService()..release.complete();
      final indexEntered = Completer<void>(), indexRelease = Completer<void>();
      final incremental = ControlledTranscriptIndex()
        ..beforeApply = (call, request) async {
          if (!indexEntered.isCompleted) indexEntered.complete();
          await indexRelease.future;
        };
      final server = Server.create(services: [rag, incremental]);
      final socket = '${temporary.path}/h.sock';
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final helper = Helper(socket, '${temporary.path}/helper');
      final store = Store('${temporary.path}/app.db');
      final domain = PausingDomain(store, helper);
      final app = Application(domain);
      addTearDown(() async {
        domain.resumeSources();
        if (!indexRelease.isCompleted) indexRelease.complete();
        await app.close();
        domain.close();
        await helper.close();
        await server.shutdown();
        store.close();
      });
      final meeting = store.meeting('Shared finalizer');
      store.transcript(meeting, 'Captured speech', true, 0, 1000, 'microphone');
      final recording = HeldStopRecording();
      app.recording = recording;
      app.recordingMeeting = meeting;
      addTearDown(() {
        if (!recording.release.isCompleted) recording.release.complete();
      });
      var current = true;
      final first = app.call('meetings.stop', {}, current: () => current);
      final cancelled = expectLater(
        first,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      var secondDone = false;
      final second = app.call('meetings.stop', {}).then((v) {
        secondDone = true;
        return v;
      });
      await recording.entered.future;
      domain.pauseSources();
      await eventually(() => domain.cancellationWatchCount >= 2);
      current = false;
      domain.checkCancellations();
      await cancelled;
      expect(secondDone, false);
      expect(app.recording, same(recording));
      recording.release.complete();
      await second;
      expect(app.recording, isNull);
      expect(app.backgroundBusy, true);
      expect(
        incremental.requests,
        isEmpty,
        reason:
            'Paused durable indexing retains intent without helper admission',
      );
      domain.resumeSources();
      await indexEntered.future;
      expect(
        indexRelease.isCompleted,
        false,
        reason: 'Indexing no longer owns capture finalization',
      );
      indexRelease.complete();
      await app.indexMeeting(meeting);
      expect(
        store.rows('SELECT state FROM meetings WHERE id=?', [
          meeting,
        ]).single['state'],
        'completed',
      );
      expect(domain.cancellationWatchCount, 0);
    },
  );
  test(
    'cancelled refresh waiter does not cancel maintenance-started Google work',
    () async {
      final temporary = createTestTempDirectorySync('google-shared-');
      final fixture = GoogleFixture();
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${temporary.path}/google'),
        secretStore: const UnavailableSecretStore(),
        endpoints: fixture.endpoints,
      )..client = GoogleClient('fixture.apps.googleusercontent.com', '');
      final helper = Helper(
        '${temporary.path}/h.sock',
        '${temporary.path}/helper',
      );
      final store = Store('${temporary.path}/app.db');
      final domain = PausedAdapterDomain(store, helper);
      final app = Application(domain, auth: auth);
      addTearDown(() async {
        domain.resumeSources();
        await app.close();
        domain.close();
        await helper.close();
        store.close();
        await fixture.close();
      });
      await auth.signIn(fixture.consent);
      await app.google.importDriveFile('doc');
      fixture.document = 'Updated shared Google text';
      fixture.modified = 'v2';
      store.setPreference('googleRefreshHours', '0');
      fixture.onExport = domain.pauseSources;
      final shared = app.maintainGoogle();
      await domain.pausedCheckpoint.future;
      var current = true;
      final leased = app.call('google.refresh', {}, current: () => current);
      final cancelled = expectLater(
        leased,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await eventually(() => domain.cancellationWatchCount == 1);
      current = false;
      domain.checkCancellations();
      await cancelled;
      expect(domain.cancellationWatchCount, 0);
      expect(app.google.syncing, true);
      domain.resumeSources();
      await shared;
      expect(store.sources.single['content'], 'Updated shared Google text');
      expect(app.google.syncing, false);
    },
  );
}
