// A separate owner lets the parent kill a microtask-starved producer without
// hanging the test isolate that owns the watchdog and captures diagnostics.
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:grpc/grpc.dart';

class NotReadyRag extends RagServiceBase {
  int calls = 0;
  bool ready = false;
  @override
  Future<IndexResponse> indexDocument(
    ServiceCall call,
    IndexRequest request,
  ) async {
    calls++;
    if (ready) return IndexResponse(success: true);
    throw GrpcError.failedPrecondition('Pipeline not initialized');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> main(List<String> arguments) async {
  final root = arguments[0], ownership = arguments[1], readiness = arguments[2];
  final store = Store('$root/profile.db');
  final peer = NotReadyRag();
  final server = Server.create(services: [peer]);
  final socket = '$root/helper.sock';
  await server.serve(
    address: InternetAddress(socket, type: InternetAddressType.unix),
    port: 0,
  );
  final helper = Helper(socket, '$root/helper', manageProcess: false);
  if (readiness == 'unconfigured') {
    helper.snapshot = control.State(pipeline: 'unconfigured');
  }
  final domain = Domain(store, helper);
  final app = Application(domain);
  try {
    final meeting = store.meeting('Readiness fixture');
    if (ownership == 'manual') {
      store.transcript(meeting, 'committed capture', true, 0, 10, 'microphone');
    }
    final id = 'meeting-$meeting';
    store.importText(
      'Retained source',
      'committed stored body',
      'text/plain',
      '${ownership == 'manual' ? 'user edit; ' : ''}meeting:$meeting',
      id: id,
      generated: ownership == 'historical',
    );
    stdout.writeln('admitted $ownership $readiness');
    await stdout.flush();
    final eventLoop = Completer<void>();
    Timer.run(eventLoop.complete);
    await app.indexMeeting(meeting);
    await eventLoop.future;
    stdout.writeln('index_returned');
    await app.recoverMeetingIndexes();
    stdout.writeln('recover_returned');
    if (store.rows('SELECT * FROM meeting_index_jobs').length != 1 ||
        store.sourceQueries.source(id)?.state != 'pending' ||
        store.sourceQueries.source(id)?.content != 'committed stored body') {
      throw StateError(
        'Pending readiness must retain one intent and its committed body',
      );
    }
    final expectedCalls = readiness == 'unconfigured' ? 0 : 2;
    if (peer.calls != expectedCalls) {
      throw StateError(
        'Readiness retried without a new owner signal: ${peer.calls}',
      );
    }
    stdout.writeln('retained_intent calls=${peer.calls}');
    peer.ready = true;
    helper.snapshot = control.State(pipeline: 'ready');
    await app.recoverMeetingIndexes();
    if (store.rows('SELECT * FROM meeting_index_jobs').isNotEmpty ||
        store.sourceQueries.source(id)?.state != 'indexed' ||
        store.sourceQueries.source(id)?.content != 'committed stored body' ||
        peer.calls != expectedCalls + 1) {
      throw StateError(
        'Actual readiness must complete the retained producer exactly once',
      );
    }
    stdout.writeln('readiness_returned calls=${peer.calls}');
  } finally {
    await app.close();
    domain.close();
    await domain.drain();
    await helper.close();
    await server.shutdown();
    store.close();
  }
}
