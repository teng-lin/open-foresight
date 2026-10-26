import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart' as rag;
import 'package:foresight_core/src/generated/transcript_index.pb.dart' as wire;
import 'package:foresight_core/src/persistence/meeting_index_jobs.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/test_recording.dart';
import 'package:foresight_test_support/transcript_index_service.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

final class _Index extends ControlledTranscriptIndex {
  Completer<void>? cursorEntered, cursorRelease;
  @override
  Future<wire.TranscriptCursor> getCursor(
    ServiceCall call,
    wire.TranscriptCursorRequest request,
  ) async {
    if (cursorEntered?.isCompleted == false) cursorEntered!.complete();
    await cursorRelease?.future;
    return super.getCursor(call, request);
  }
}

final class _Retrieval extends rag.RagServiceBase {
  _Retrieval(this.index);
  final ControlledTranscriptIndex index;
  final ordinary = <String, String>{};
  final requests = <rag.RetrieveRequest>[];
  @override
  Future<rag.RetrieveResponse> retrieveContext(
    ServiceCall call,
    rag.RetrieveRequest request,
  ) async {
    requests.add(request);
    return rag.RetrieveResponse(
      chunks: [
        for (final id in request.allowedDocumentIds)
          if (ordinary.containsKey(id) || index.pieces.containsKey(id))
            rag.RetrievedChunk(
              documentId: id,
              text:
                  ordinary[id] ??
                  index.pieces[id]!.values.map((p) => p.text).join('\n'),
              relevanceScore: .9,
            ),
      ],
    );
  }

  @override
  Future<rag.DeleteResponse> deleteDocument(
    ServiceCall call,
    rag.DeleteRequest request,
  ) async {
    ordinary.remove(request.documentId);
    index.pieces.remove(request.documentId);
    return rag.DeleteResponse(success: true);
  }

  @override
  Future<rag.IndexResponse> indexDocument(
    ServiceCall call,
    rag.IndexRequest request,
  ) async {
    ordinary[request.documentId] = request.content;
    return rag.IndexResponse(success: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  bootstrapSqlSupportFixture();
  late Store store;
  late Domain domain;
  late Helper helper;
  late Application app;
  late Server server;
  late _Index peer;
  late _Retrieval retrieval;
  late Map<String, Completer<void>> entered, release;
  late int meeting;
  var reject = false;
  String id(int value) => 'meeting-$value';
  Matcher busy() =>
      isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy);
  Matcher cancelled() =>
      isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled);
  Future<Object?> search({bool Function()? current}) =>
      app.call('sources.search', {'query': 'draft'}, current: current);
  int stoppedMeeting(String title) {
    final result = store.meeting(title);
    store.transcript(
      result,
      'Mira sends the draft.',
      true,
      0,
      1000,
      'microphone',
    );
    store.db.execute("UPDATE meetings SET state='completed' WHERE id=?", [
      result,
    ]);
    return result;
  }

  Future<void> hold(int value) {
    entered[id(value)] = Completer<void>();
    release[id(value)] = Completer<void>();
    final work = app.indexMeeting(value);
    work.ignore();
    return work;
  }

  Future<void> started(int value) =>
      entered[id(value)]!.future.timeout(const Duration(seconds: 2));
  void finish(int value) {
    final gate = release[id(value)]!;
    if (!gate.isCompleted) gate.complete();
  }

  void ordinary() {
    store.importText(
      'Ordinary',
      'Previously indexed passage',
      'text/plain',
      'fixture',
      id: 'ordinary',
    );
    store.state('ordinary', 'indexed');
    retrieval.ordinary['ordinary'] = 'Previously indexed passage';
  }

  setUp(() async {
    final root = createTestTempDirectorySync('search-ready-');
    store = Store('${root.path}/app.db');
    entered = {};
    release = {};
    reject = false;
    peer = _Index()
      ..beforeApply = (call, request) async {
        final signal = entered[request.documentId];
        if (signal != null && !signal.isCompleted) signal.complete();
        await release[request.documentId]?.future;
        if (reject) {
          throw GrpcError.unavailable('Controlled failed final delta');
        }
      };
    retrieval = _Retrieval(peer);
    server = Server.create(services: [peer, retrieval]);
    final socket = '${root.path}/helper.sock';
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    helper = Helper(socket, '${root.path}/helper', manageProcess: false)
      ..snapshot = control.State(
        instanceId: 'readiness-fixture',
        pipeline: 'ready',
        model: control.ModelIdentity(modelDigest: 'embedding-fixture'),
      );
    domain = Domain(store, helper);
    app = Application(domain);
    meeting = stoppedMeeting('Stopped meeting');
    addTearDown(() async {
      for (final gate in release.values) {
        if (!gate.isCompleted) gate.complete();
      }
      if (peer.cursorRelease?.isCompleted == false) {
        peer.cursorRelease!.complete();
      }
      await app.close();
      domain.close();
      await domain.drain();
      await helper.close();
      await server.shutdown();
      store.close();
    });
    // Warm the actual Domain/client/server cursor path before any operation
    // clock. Domain still opens a fresh owned channel for each subsequent RPC.
    // The unused ID cannot project a meeting or change durable indexing state.
    final jobsBefore = store.rows('SELECT * FROM meeting_index_jobs');
    final sourcesBefore = store.rows('SELECT * FROM sources');
    final warmup = await domain
        .transcriptCursor('readiness-warmup')
        .timeout(const Duration(seconds: 5));
    expect(warmup.exists, false);
    expect(peer.cursorReads, 1);
    expect(peer.requests, isEmpty);
    expect(peer.cursors, isEmpty);
    expect(peer.pieces, isEmpty);
    expect(store.rows('SELECT * FROM meeting_index_jobs'), jobsBefore);
    expect(store.rows('SELECT * FROM sources'), sourcesBefore);
  });
  test(
    'Stop returns independently while immediate Search waits for the accepted final delta',
    () async {
      // The production Stop path schedules final work without waiting on helper.
      entered[id(meeting)] = Completer<void>();
      release[id(meeting)] = Completer<void>();
      app.recording = TestRecording();
      app.recordingMeeting = meeting;
      await app.stopRecording().timeout(const Duration(seconds: 1));
      expect(app.recording, isNull);
      await started(meeting);
      final baseline = domain.cancellationWatchCount;
      final result = search();
      await eventually(() => domain.cancellationWatchCount > baseline);
      expect(retrieval.requests, isEmpty);
      expect(release[id(meeting)]!.isCompleted, false);
      // Await actual producer settlement before measuring the reply envelope.
      // The original Search is already running with its production five-second
      // deadline; neither settlement observation nor this reply wait renews it.
      result.ignore();
      finish(meeting);
      await eventually(
        () =>
            store.rows('SELECT * FROM meeting_index_jobs').isEmpty &&
            store.sourceQueries.source(id(meeting))?.state == 'indexed',
      );
      final rows = await result.timeout(const Duration(seconds: 2)) as List;
      expect(rows.single['id'], id(meeting));
      expect(rows.single['text'], contains('Mira sends the draft.'));
      expect(store.rows('SELECT * FROM meeting_index_jobs'), isEmpty);
    },
  );
  test(
    'cancelling a search disposes its waiter and leaves shared indexing owned',
    () async {
      final work = hold(meeting);
      await started(meeting);
      final baseline = domain.cancellationWatchCount;
      var current = true;
      final result = search(current: () => current);
      final failed = expectLater(result, throwsA(cancelled()));
      await eventually(() => domain.cancellationWatchCount > baseline);
      current = false;
      domain.checkCancellations();
      await failed.timeout(const Duration(seconds: 1));
      expect(domain.cancellationWatchCount, baseline);
      expect(release[id(meeting)]!.isCompleted, false);
      finish(meeting);
      await work;
      expect((await search() as List).single['id'], id(meeting));
    },
  );
  test(
    'workspace invalidation cancels the fixed snapshot instead of returning reused IDs',
    () async {
      final work = hold(meeting);
      await started(meeting);
      final baseline = domain.cancellationWatchCount;
      final result = search();
      final failed = expectLater(result, throwsA(cancelled()));
      await eventually(() => domain.cancellationWatchCount > baseline);
      final clearing = app.call('workspace.clear', {});
      clearing.ignore();
      await failed.timeout(const Duration(seconds: 1));
      expect(retrieval.requests, isEmpty);
      finish(meeting);
      await work.catchError((Object _) {});
      await clearing;
      expect(store.rows('SELECT * FROM meeting_index_jobs'), isEmpty);
      expect(store.meeting('Replacement after clear'), meeting);
    },
  );
  for (final transition in [
    'delete',
    'manual',
    'pause',
    'unconfigured',
    'live',
  ]) {
    test(
      '$transition retires only the captured target without cancelling shared ownership',
      () async {
        ordinary();
        final work = hold(meeting);
        await started(meeting);
        final baseline = domain.cancellationWatchCount;
        final result = search();
        await eventually(() => domain.cancellationWatchCount > baseline);
        Future<void>? deletion;
        switch (transition) {
          case 'delete':
            deletion = domain.delete(id(meeting));
          case 'manual':
            store.importText(
              'Manual text',
              'User-edited content',
              'text/plain',
              'fixture',
              id: id(meeting),
              locallyEdited: true,
            );
            domain.checkCancellations();
          case 'pause':
            domain.pauseSources();
          case 'unconfigured':
            helper.snapshot = control.State(pipeline: 'unconfigured');
          case 'live':
            store.db.execute(
              "UPDATE meetings SET state='recording' WHERE id=?",
              [meeting],
            );
            store.transcript(
              meeting,
              'Future live speech',
              true,
              1000,
              2000,
              'microphone',
            );
        }
        app.changed();
        final rows = await result.timeout(const Duration(seconds: 1)) as List;
        expect(rows.map((row) => row['id']), contains('ordinary'));
        expect(release[id(meeting)]!.isCompleted, false);
        finish(meeting);
        domain.resumeSources();
        helper.snapshot = control.State(
          instanceId: 'readiness-fixture',
          pipeline: 'ready',
          model: control.ModelIdentity(modelDigest: 'embedding-fixture'),
        );
        await work.catchError((Object _) {});
        await deletion;
      },
    );
  }
  test(
    'a still-stopped superseding revision refuses rather than chasing future content',
    () async {
      final work = hold(meeting);
      await started(meeting);
      final baseline = domain.cancellationWatchCount;
      final result = search();
      final failed = expectLater(result, throwsA(busy()));
      await eventually(() => domain.cancellationWatchCount > baseline);
      store.transcript(
        meeting,
        'A newer stopped revision',
        true,
        1000,
        2000,
        'microphone',
      );
      app.changed();
      await failed.timeout(const Duration(seconds: 1));
      expect(retrieval.requests, isEmpty);
      expect(release[id(meeting)]!.isCompleted, false);
      finish(meeting);
      await work;
    },
  );
  test(
    'later live producers do not extend a captured stopped-search snapshot',
    () async {
      final work = hold(meeting);
      await started(meeting);
      final baseline = domain.cancellationWatchCount;
      final result = search();
      await eventually(() => domain.cancellationWatchCount > baseline);
      final later = stoppedMeeting('Future capture');
      store.db.execute("UPDATE meetings SET state='recording' WHERE id=?", [
        later,
      ]);
      final futureWork = hold(later);
      app.changed();
      finish(meeting);
      await work;
      await started(later);
      final rows = await result.timeout(const Duration(seconds: 1)) as List;
      expect(rows.map((row) => row['id']), contains(id(meeting)));
      expect(rows.map((row) => row['id']), isNot(contains(id(later))));
      expect(release[id(later)]!.isCompleted, false);
      finish(later);
      await futureWork;
    },
  );
  test(
    'later stopped producers do not extend a captured stopped-search snapshot',
    () async {
      final work = hold(meeting);
      await started(meeting);
      final baseline = domain.cancellationWatchCount;
      final result = search();
      await eventually(() => domain.cancellationWatchCount > baseline);
      final later = stoppedMeeting('Future capture');
      store.db.execute("UPDATE meetings SET state='completed' WHERE id=?", [
        later,
      ]);
      final futureWork = hold(later);
      app.changed();
      finish(meeting);
      await work;
      await started(later);
      final rows = await result.timeout(const Duration(seconds: 1)) as List;
      expect(rows.map((row) => row['id']), contains(id(meeting)));
      expect(rows.map((row) => row['id']), isNot(contains(id(later))));
      expect(release[id(later)]!.isCompleted, false);
      finish(later);
      await futureWork;
    },
  );
  test(
    'a held final delta reaches the fixed five-second readiness deadline',
    () async {
      final work = hold(meeting);
      await started(meeting);
      final elapsed = Stopwatch()..start();
      await expectLater(
        search(),
        throwsA(busy()),
      ).timeout(const Duration(seconds: 7));
      expect(elapsed.elapsed, greaterThanOrEqualTo(const Duration(seconds: 5)));
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 7)));
      expect(retrieval.requests, isEmpty);
      expect(release[id(meeting)]!.isCompleted, false);
      finish(meeting);
      await work;
    },
  );
  for (final readiness in ['paused', 'unconfigured']) {
    test(
      '$readiness admission does not wait on durable stopped work',
      () async {
        ordinary();
        MeetingIndexJobs.forStore(store).request(meeting);
        if (readiness == 'paused') {
          domain.pauseSources();
        } else {
          helper.snapshot = control.State(pipeline: 'unconfigured');
        }
        final rows = await search().timeout(const Duration(seconds: 1)) as List;
        expect(rows.single['id'], 'ordinary');
        expect(peer.requests, isEmpty);
        expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(1));
      },
    );
  }
  test(
    'an older indexed flag cannot bypass a new helper verification job',
    () async {
      final first = hold(meeting);
      await started(meeting);
      finish(meeting);
      await first;
      peer.pieces.clear();
      peer.cursors.clear();
      peer.cursorEntered = Completer<void>();
      peer.cursorRelease = Completer<void>();
      final verifying = app.indexMeeting(meeting);
      verifying.ignore();
      await peer.cursorEntered!.future.timeout(const Duration(seconds: 1));
      final baseline = domain.cancellationWatchCount;
      final result = search();
      await eventually(() => domain.cancellationWatchCount > baseline);
      expect(retrieval.requests, isEmpty);
      peer.cursorRelease!.complete();
      await verifying;
      final rows = await result.timeout(const Duration(seconds: 2)) as List;
      expect(rows.single['id'], id(meeting));
      expect(rows.single['text'], contains('Mira sends the draft.'));
    },
  );
  test(
    'captured producer failure refuses this call but later ordinary search remains available',
    () async {
      ordinary();
      final work = hold(meeting);
      await started(meeting);
      reject = true;
      final baseline = domain.cancellationWatchCount;
      final result = search();
      final failed = expectLater(result, throwsA(busy()));
      await eventually(() => domain.cancellationWatchCount > baseline);
      finish(meeting);
      await failed.timeout(const Duration(seconds: 1));
      finish(meeting);
      await work.catchError((Object _) {});
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(1));
      expect(retrieval.requests, isEmpty);
      final calls = peer.requests.length;
      final later = await search() as List;
      expect(later.single['id'], 'ordinary');
      expect(peer.requests, hasLength(calls));
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(1));
    },
  );
  test(
    'readiness waiter capacity is bounded and cancellation releases every slot',
    () async {
      final work = hold(meeting);
      await started(meeting);
      final baseline = domain.cancellationWatchCount;
      var current = true;
      final waits = <Future<void>>[];
      for (var n = 0; n < 64; n++) {
        waits.add(
          expectLater(search(current: () => current), throwsA(cancelled())),
        );
      }
      await eventually(() => domain.cancellationWatchCount == baseline + 64);
      await expectLater(
        search(),
        throwsA(busy()),
      ).timeout(const Duration(seconds: 1));
      current = false;
      domain.checkCancellations();
      await Future.wait(waits);
      expect(domain.cancellationWatchCount, baseline);
      var replacementCurrent = true;
      final replacement = expectLater(
        search(current: () => replacementCurrent),
        throwsA(cancelled()),
      );
      await eventually(() => domain.cancellationWatchCount == baseline + 1);
      replacementCurrent = false;
      domain.checkCancellations();
      await replacement;
      finish(meeting);
      await work;
    },
  );
  test(
    'caller invalidation after an empty readiness snapshot precedes retrieval',
    () async {
      ordinary();
      var current = true;
      final result = search(current: () => current);
      current = false;
      await expectLater(result, throwsA(cancelled()));
      expect(retrieval.requests, isEmpty);
    },
  );
  test(
    'unstarted durable backlog preserves ordinary results without a hot retry',
    () async {
      ordinary();
      MeetingIndexJobs.forStore(store).request(meeting);
      final rows = await search().timeout(const Duration(seconds: 1)) as List;
      expect(rows.single['id'], 'ordinary');
      expect(peer.requests, isEmpty);
      expect(retrieval.requests, hasLength(1));
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(1));
    },
  );
  test(
    'stale backlog cannot hide an active stopped producer behind the snapshot limit',
    () async {
      final jobs = MeetingIndexJobs.forStore(store)..request(meeting);
      for (var n = 0; n < 64; n++) {
        jobs.request(stoppedMeeting('Backlog $n'));
      }
      final active = stoppedMeeting('Accepted final transcript');
      final work = hold(active);
      await started(active);
      final baseline = domain.cancellationWatchCount;
      final result = search();
      result.ignore();
      await eventually(() => domain.cancellationWatchCount > baseline);
      expect(retrieval.requests, isEmpty);
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(66));
      finish(active);
      await work;
      final rows = await result.timeout(const Duration(seconds: 2)) as List;
      expect(rows.single['id'], id(active));
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(65));
    },
  );
}
