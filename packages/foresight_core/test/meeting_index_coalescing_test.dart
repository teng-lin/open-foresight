import 'package:foresight_core/src/rpc_error.dart';
import 'dart:async';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/transcript_index_service.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class MeetingIndexService extends RagServiceBase {
  final entered = Completer<void>(), release = Completer<void>();
  final requests = <IndexRequest>[];
  bool reject = false;
  @override
  Future<IndexResponse> indexDocument(
    ServiceCall call,
    IndexRequest request,
  ) async {
    requests.add(request);
    if (!entered.isCompleted) entered.complete();
    await release.future;
    if (reject) throw GrpcError.unavailable('fixture index failure');
    return IndexResponse(success: true);
  }

  @override
  Future<DeleteResponse> deleteDocument(
    ServiceCall call,
    DeleteRequest request,
  ) async => DeleteResponse(success: true);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late Store store, reader;
  late Helper helper;
  late Domain domain;
  late Application app;
  late Server server;
  late MeetingIndexService service;
  late ControlledTranscriptIndex incremental;
  late int meeting;
  setUp(() async {
    root = createTestTempDirectorySync('meeting-index-');
    store = Store('${root.path}/app.db');
    reader = Store.readOnly(store.path);
    service = MeetingIndexService();
    incremental = ControlledTranscriptIndex()
      ..beforeApply = (call, request) async {
        service.requests.add(
          IndexRequest(
            documentId: request.documentId,
            content: request.upserts.map((piece) => piece.text).join('\n'),
          ),
        );
        if (!service.entered.isCompleted) service.entered.complete();
        await service.release.future;
        if (service.reject) {
          throw GrpcError.unavailable('fixture index failure');
        }
      };
    server = Server.create(services: [service, incremental]);
    final socket = '${root.path}/helper.sock';
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    helper = Helper(socket, '${root.path}/helper', manageProcess: false);
    helper.snapshot = control.State(
      instanceId: 'fixture',
      model: control.ModelIdentity(modelDigest: 'original-model'),
    );
    domain = Domain(store, helper);
    app = Application(domain);
    meeting = store.meeting('Capture');
    store.transcript(
      meeting,
      'Original final speech',
      true,
      0,
      10,
      'microphone',
    );
  });
  setUp(() {
    addTearDown(() async {
      if (!service.release.isCompleted) service.release.complete();
      await app.close();
      domain.close();
      await helper.close();
      await server.shutdown();
      reader.close();
      store.close();
      root.deleteSync(recursive: true);
    });
  });
  test(
    'paused live and stop requests share one index and publish to read-only clients',
    () async {
      domain.pauseSources();
      await app.indexMeeting(meeting);
      await app.indexMeeting(meeting);
      expect(service.requests, isEmpty);
      domain.resumeSources();
      await service.entered.future.timeout(const Duration(seconds: 5));
      expect(reader.sources.single['state'], 'indexing');
      service.release.complete();
      await app.indexMeeting(meeting);
      expect(service.requests, hasLength(1));
      expect(reader.sources.single['state'], 'indexed');
      expect(reader.sources.single['revision'], 1);
      await app.indexMeeting(meeting);
      expect(service.requests, hasLength(1));
      // A later explicit retry must not reuse an already completed future.
      store.state('meeting-$meeting', 'pending');
      final cursorReads = incremental.cursorReads;
      await app.indexMeeting(meeting);
      expect(incremental.cursorReads, greaterThan(cursorReads));
      expect(
        service.requests,
        hasLength(1),
        reason: 'Confirmed incremental state needs no duplicate embedding',
      );
      expect(reader.sources.single['state'], 'indexed');
    },
  );
  test(
    'new transcript revisions remain separate while an old index is in flight',
    () async {
      final first = app.indexMeeting(meeting);
      await service.entered.future.timeout(const Duration(seconds: 5));
      store.transcript(
        meeting,
        'Additional speech',
        true,
        10,
        20,
        'microphone',
      );
      final second = app.indexMeeting(meeting);
      service.release.complete();
      await Future.wait([first, second]);
      expect(service.requests, hasLength(2));
      expect(service.requests.last.content, contains('Additional speech'));
      expect(reader.sources.single['revision'], 2);
      expect(reader.sources.single['state'], 'indexed');
    },
  );
  test('failed work is evicted so a real retry reaches the helper', () async {
    service.reject = true;
    service.release.complete();
    await expectLater(app.indexMeeting(meeting), throwsA(isA<GrpcError>()));
    expect(reader.sources.single['state'], 'failed');
    service.reject = false;
    await app.indexMeeting(meeting);
    expect(service.requests, hasLength(2));
    expect(reader.sources.single['revision'], 1);
    expect(reader.sources.single['state'], 'indexed');
  });
  for (final change in <String, void Function(control.State)>{
    'helper instance': (state) => state.instanceId = 'replacement-owner',
    'active generation': (state) => state.activeGeneration += 1,
    'pending generation': (state) => state.pendingGeneration += 1,
    'model identity': (state) => state.model.modelDigest = 'replacement-model',
  }.entries) {
    test('new ${change.key} does not coalesce with active old work', () async {
      final first = app.indexMeeting(meeting);
      await service.entered.future.timeout(const Duration(seconds: 5));
      change.value(helper.snapshot!);
      final second = app.indexMeeting(meeting);
      service.release.complete();
      await Future.wait([first, second]);
      expect(service.requests, hasLength(2));
      expect(reader.sources.single['state'], 'indexed');
    });
  }
  test(
    'workspace invalidation keeps new requests independent of old work',
    () async {
      final first = app.indexMeeting(meeting);
      final failedFirst = expectLater(
        first,
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.cancelled,
          ),
        ),
      );
      await service.entered.future.timeout(const Duration(seconds: 5));
      domain.invalidateWorkspace();
      final second = app.indexMeeting(meeting);
      service.release.complete();
      await failedFirst;
      await second;
      expect(service.requests, hasLength(2));
      expect(reader.sources.single['state'], 'indexed');
    },
  );
}
