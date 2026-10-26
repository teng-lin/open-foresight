import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart' as rag;
import 'package:foresight_core/src/generated/transcript_index.pbgrpc.dart'
    as transcript;
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class HeldRag extends rag.RagServiceBase {
  final entered = Completer<void>(), release = Completer<void>();
  final calls = <ServiceCall>[];
  final peerEntered = Completer<void>(), peerRelease = Completer<void>();
  ServiceCall? peer;
  @override
  Future<rag.PingResponse> ping(
    ServiceCall call,
    rag.PingRequest request,
  ) async {
    peer = call;
    if (!peerEntered.isCompleted) peerEntered.complete();
    await peerRelease.future;
    return rag.PingResponse(success: true);
  }

  @override
  Future<rag.IndexResponse> indexDocument(
    ServiceCall call,
    rag.IndexRequest request,
  ) async {
    calls.add(call);
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return rag.IndexResponse(success: true);
  }

  @override
  Future<rag.DeleteResponse> deleteDocument(
    ServiceCall call,
    rag.DeleteRequest request,
  ) async => rag.DeleteResponse(success: true);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class HeldTranscript extends transcript.TranscriptIndexServiceBase {
  final entered = Completer<void>(), release = Completer<void>();
  final calls = <ServiceCall>[];
  final deltas = <transcript.TranscriptDelta>[];
  @override
  Future<transcript.TranscriptDeltaResult> applyDelta(
    ServiceCall call,
    transcript.TranscriptDelta request,
  ) async {
    calls.add(call);
    deltas.add(request);
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return transcript.TranscriptDeltaResult(
      applied: true,
      revision: request.revision,
    );
  }

  @override
  Future<transcript.TranscriptCursor> getCursor(
    ServiceCall call,
    transcript.TranscriptCursorRequest request,
  ) async {
    calls.add(call);
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return transcript.TranscriptCursor(exists: false);
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late Store store;
  late Helper helper;
  late Domain domain;
  late Server server;
  late HeldRag legacy;
  late HeldTranscript incremental;
  late String source;
  Matcher cancelled() => isA<RpcError>().having(
    (error) => error.code,
    'code',
    RpcErrorCode.cancelled,
  );
  transcript.TranscriptDelta delta() => transcript.TranscriptDelta(
    documentId: source,
    workspaceEpoch: 'fixture-epoch',
    revision: Int64.ONE,
    upserts: [
      transcript.TranscriptSegment(
        key: transcript.TranscriptKey(segmentId: Int64.ONE),
        text: 'new immutable evidence',
        startMs: Int64.ZERO,
        endMs: Int64(1000),
      ),
    ],
  );
  setUp(() async {
    root = createTestTempDirectorySync('delta-domain-');
    store = Store('${root.path}/app.db');
    final socket = '${root.path}/helper.sock';
    legacy = HeldRag();
    incremental = HeldTranscript();
    server = Server.create(services: [legacy, incremental]);
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    helper = Helper(socket, '${root.path}/helper', manageProcess: false);
    domain = Domain(store, helper);
    source = store.importText(
      'Controlled source',
      'committed evidence',
      'text/plain',
      'fixture',
    );
    addTearDown(() async {
      if (!legacy.release.isCompleted) legacy.release.complete();
      if (!legacy.peerRelease.isCompleted) legacy.peerRelease.complete();
      if (!incremental.release.isCompleted) incremental.release.complete();
      domain.close();
      await helper.close();
      await server.shutdown();
      store.close();
    });
  });
  for (final oldApi in [true, false]) {
    test(
      '${oldApi ? 'legacy index' : 'transcript delta'} producer cancellation cancels and joins the actual RPC',
      () async {
        var current = true;
        final work = oldApi
            ? domain.index(source, current: () => current)
            : domain.applyTranscriptDelta(delta(), current: () => current);
        final rejected = expectLater(work, throwsA(cancelled()));
        await (oldApi ? legacy.entered.future : incremental.entered.future);
        expect(domain.mutating, 1);
        current = false;
        domain.checkCancellations();
        await rejected.timeout(const Duration(seconds: 3));
        final call = oldApi ? legacy.calls.single : incremental.calls.single;
        await eventually(() => call.isCanceled);
        expect(domain.mutating, 0);
        expect(domain.cancellationWatchCount, 0);
        if (oldApi) {
          expect(
            store.rows('SELECT state FROM sources WHERE id=?', [
              source,
            ]).single['state'],
            'pending',
          );
        }
        // The canceled call's late acknowledgement cannot publish indexed state.
        legacy.release.complete();
        incremental.release.complete();
        await domain.index(source);
        expect(
          store.rows('SELECT state FROM sources WHERE id=?', [
            source,
          ]).single['state'],
          'indexed',
        );
      },
    );
    test(
      '${oldApi ? 'legacy index' : 'transcript delta'} closes while paused without dispatching work',
      () async {
        domain.pauseSources();
        var current = true;
        final work = oldApi
            ? domain.index(source, current: () => current)
            : domain.applyTranscriptDelta(delta(), current: () => current);
        final rejected = expectLater(work, throwsA(cancelled()));
        await eventually(() => domain.cancellationWatchCount > 0);
        current = false;
        domain.checkCancellations();
        await rejected.timeout(const Duration(seconds: 3));
        expect(domain.mutating, 0);
        expect(domain.cancellationWatchCount, 0);
        expect(legacy.calls, isEmpty);
        expect(incremental.calls, isEmpty);
      },
    );
  }
  test(
    'cursor producer owns cancellation and leaves no reservation or watch',
    () async {
      var current = true;
      final work = domain.transcriptCursor(source, current: () => current);
      final rejected = expectLater(work, throwsA(cancelled()));
      await incremental.entered.future;
      current = false;
      domain.checkCancellations();
      await rejected.timeout(const Duration(seconds: 3));
      await eventually(() => incremental.calls.single.isCanceled);
      expect(domain.mutating, 0);
      expect(domain.cancellationWatchCount, 0);
    },
  );
  test(
    'subscriber cancellation does not cancel the durable producer',
    () async {
      final producer = domain.applyTranscriptDelta(
        delta(),
        current: () => true,
      );
      await incremental.entered.future;
      var subscribed = true;
      final observer = domain.awaitCurrent(producer, () => subscribed);
      final rejected = expectLater(observer, throwsA(cancelled()));
      subscribed = false;
      domain.checkCancellations();
      await rejected;
      expect(incremental.calls.single.isCanceled, false);
      expect(domain.mutating, 1);
      incremental.release.complete();
      final result = await producer;
      expect(result.applied, true);
      expect(result.revision, Int64.ONE);
      expect(domain.mutating, 0);
      expect(domain.cancellationWatchCount, 0);
    },
  );
  test(
    'producer cancellation leaves a concurrent shared-helper RPC intact',
    () async {
      var current = true;
      final producer = domain.applyTranscriptDelta(
        delta(),
        current: () => current,
      );
      final rejected = expectLater(producer, throwsA(cancelled()));
      await incremental.entered.future;
      final peer = helper.client.ping(rag.PingRequest());
      await legacy.peerEntered.future;
      current = false;
      domain.checkCancellations();
      await rejected;
      expect(legacy.peer!.isCanceled, false);
      legacy.peerRelease.complete();
      expect((await peer).success, true);
      expect(domain.mutating, 0);
    },
  );
  test(
    'Domain close cancels its delta RPC without an explicit owner predicate',
    () async {
      final producer = domain.applyTranscriptDelta(delta());
      final rejected = expectLater(producer, throwsA(cancelled()));
      await incremental.entered.future;
      domain.close();
      await rejected.timeout(const Duration(seconds: 3));
      await eventually(() => incremental.calls.single.isCanceled);
      expect(domain.mutating, 0);
      expect(domain.cancellationWatchCount, 0);
    },
  );
  test(
    'workspace invalidation cancels old delta and preserves next generation independence',
    () async {
      final producer = domain.applyTranscriptDelta(delta());
      final rejected = expectLater(producer, throwsA(cancelled()));
      await incremental.entered.future;
      domain.invalidateWorkspace();
      await rejected.timeout(const Duration(seconds: 3));
      await eventually(() => incremental.calls.single.isCanceled);
      incremental.release.complete();
      final replacement = await domain.applyTranscriptDelta(delta());
      expect(replacement.applied, true);
      expect(incremental.deltas, hasLength(2));
      expect(domain.mutating, 0);
    },
  );
}
