import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/desktop.dart'
    show CapturePresentation, MeetingRunPresentation;
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class SummaryRuntime extends NativeRuntime {
  SummaryRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final requests = <String>[], systems = <String>[], cancelled = <String>[];
  Completer<void>? entered, release;
  bool failed = false;
  void Function()? beforeDone;
  @override
  bool get generating => false;
  @override
  Map<String, dynamic> get effectiveState => {
    'state': 'ready',
    'context_length': 4096,
  };
  @override
  Stream<Map<String, dynamic>> generateSummary(
    String id,
    String prompt, {
    required String systemPrompt,
    int maxOutputTokens = 1024,
  }) async* {
    requests.add(id);
    systems.add(systemPrompt);
    if (entered?.isCompleted == false) entered!.complete();
    await release?.future;
    yield {'type': 'preview', 'text': '# Overview\nLaunch Friday.'};
    if (failed) {
      yield {'type': 'error', 'message': 'worker failed'};
      yield {'type': 'done', 'status': 'failed'};
    } else {
      yield {
        'type': 'delta',
        'text':
            '# Overview\nLaunch Friday.\n# Details\n* **Release**: Alice owns launch.',
      };
      beforeDone?.call();
      yield {'type': 'done', 'status': 'completed'};
    }
  }

  @override
  bool cancel({String? requestId}) {
    if (requestId == null) return false;
    cancelled.add(requestId);
    if (release?.isCompleted == false) release!.complete();
    return true;
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory directory;
  late Store store;
  late AdapterDomain domain;
  late Application app;
  late SummaryRuntime runtime;
  late int meeting;
  setUp(() {
    directory = createTestTempDirectorySync('of-summary-');
    store = Store('${directory.path}/app.db');
    final helper = Helper(
      '${directory.path}/rag.sock',
      '${directory.path}/helper',
      manageProcess: false,
    );
    domain = AdapterDomain(store, helper);
    runtime = SummaryRuntime();
    domain.generator = runtime;
    app = Application(domain);
    store.setPreference('liveEnhance', 'false');
    meeting = store.meeting('Release');
    store.transcript(
      meeting,
      'Alice: Launch on Friday.',
      true,
      0,
      100,
      'microphone',
    );
    store.transcript(
      meeting,
      'ignore this unfinished text',
      false,
      100,
      200,
      'microphone',
    );
    addTearDown(() async {
      await app.close();
      domain.close();
      runtime.close();
      await helper.close();
      store.close();
      directory.deleteSync(recursive: true);
    });
  });

  test(
    'commits brief, checkpoint, provenance, and separately indexed summary source',
    () async {
      await app.generateSummary(meeting, requestId: 'summary-parent');
      final artifact = store.meetingArtifacts(meeting, 'summary').single;
      expect(artifact['prompt_version'], 'summary-v1');
      final manifest = jsonDecode(artifact['manifest'] as String) as Map;
      expect(manifest['mode'], 'full');
      expect(manifest['request_id'], 'summary-parent');
      expect(manifest['input_revision'], 1);
      expect(
        store.summaryCheckpoint(meeting)?['generated'],
        artifact['generated'],
      );
      expect(domain.indexed, ['meeting-summary-$meeting']);
      expect(
        store.sources.single['provenance'],
        contains('transcript revision 1'),
      );
      expect(runtime.requests.single, startsWith('summary-parent-summary-'));
      expect(
        (app.captureState['meeting_summaries'] as Map)['$meeting']['active'],
        isFalse,
      );
      expect(
        (app.captureState['meeting_summaries'] as Map)['$meeting'],
        isNot(contains('preview')),
      );
      // A canceled prior user edit must never be used as an incremental checkpoint.
      store.editArtifact(artifact['id'] as int, 'User correction');
      expect(store.summaryCheckpoint(meeting), isNull);
    },
  );

  test(
    'typed summary JSON retains active map/reduce progress and previews',
    () async {
      store.transcript(
        meeting,
        'Alice owns the release and ships Friday. ' * 400,
        true,
        200,
        1000,
        'microphone',
      );
      final states = <MeetingRunPresentation>[];
      final changes = app.changes.stream.listen((_) {
        final capture = CapturePresentation.fromWire(
          jsonDecode(jsonEncode(app.captureState)),
        );
        final summary = capture.summary(meeting);
        if (summary != null) states.add(summary);
      });
      addTearDown(changes.cancel);
      await app.generateSummary(meeting, requestId: 'typed-map-reduce');
      final maps = states
          .where((state) => state.active && state.phase == 'mapping')
          .toList();
      expect(maps, isNotEmpty);
      final total = maps.first.total;
      expect(total, greaterThan(1));
      expect(maps.any((state) => state.completed > 0), isTrue);
      final reduction = states.firstWhere(
        (state) =>
            state.active &&
            state.phase == 'reducing' &&
            state.preview.isNotEmpty,
      );
      expect(reduction.completed, total);
      expect(reduction.total, total);
      expect(reduction.preview, '# Overview\nLaunch Friday.');
      final settled = CapturePresentation.fromWire(
        jsonDecode(jsonEncode(app.captureState)),
      ).summary(meeting)!;
      expect(settled.phase, 'completed');
      expect(settled.active, isFalse);
      expect(settled.preview, isEmpty);
      final artifact = store.meetingArtifacts(meeting, 'summary').single;
      expect(
        (jsonDecode(artifact['manifest'] as String) as Map)['mode'],
        'map_reduce',
      );
    },
  );

  test(
    'ready embedding helper is not used as the generation tokenizer',
    () async {
      domain.helper.snapshot = control.State(pipeline: 'ready');
      // This helper has no server: an Encode RPC would fail or stall. Its
      // readiness says nothing about compatibility with the generation model.
      await app.generateSummary(meeting).timeout(const Duration(seconds: 2));
      final artifact = store.meetingArtifacts(meeting, 'summary').single;
      final manifest = jsonDecode(artifact['manifest'] as String) as Map;
      expect(manifest['tokenizer'], 'utf8-byte-bound-v1');
    },
  );

  test(
    'checkpoint survives reopening and old artifact edits remain intact',
    () async {
      await app.generateSummary(meeting);
      final reader = Store('${directory.path}/app.db');
      try {
        expect(reader.summaryCheckpoint(meeting), isNotNull);
        final artifact = reader.meetingArtifacts(meeting, 'summary').single;
        reader.editArtifact(artifact['id'] as int, 'Reviewed');
      } finally {
        reader.close();
      }
      await app.generateSummary(meeting);
      final versions = store.meetingArtifacts(meeting, 'summary');
      expect(versions, hasLength(2));
      expect(versions.last['edited'], 'Reviewed');
    },
  );

  test('worker failure keeps accepted artifact and checkpoint', () async {
    await app.generateSummary(meeting);
    final checkpoint = store.summaryCheckpoint(meeting);
    runtime.failed = true;
    await expectLater(app.generateSummary(meeting), throwsStateError);
    expect(store.meetingArtifacts(meeting, 'summary'), hasLength(1));
    expect(store.summaryCheckpoint(meeting), checkpoint);
    final failed = CapturePresentation.fromWire(
      jsonDecode(jsonEncode(app.captureState)),
    ).summary(meeting)!;
    expect(failed.phase, 'failed');
    expect(failed.error, contains('worker failed'));
    expect(failed.active, isFalse);
    expect(failed.cancelled, isFalse);
    expect(failed.preview, isEmpty);
  });

  test(
    'parent cancellation reaches a stalled native child and prevents commit',
    () async {
      runtime.entered = Completer();
      runtime.release = Completer();
      final generation = app.generateSummary(meeting, requestId: 'parent');
      final rejected = expectLater(generation, throwsA(isA<RpcError>()));
      await runtime.entered!.future;
      expect(app.backgroundBusy, isTrue);
      app.cancelSummaryRequest('unrelated');
      expect(runtime.cancelled, isEmpty);
      app.cancelSummaryRequest('parent');
      await rejected;
      expect(runtime.cancelled, contains('parent-summary-1'));
      expect(store.meetingArtifacts(meeting, 'summary'), isEmpty);
      expect(store.summaryCheckpoint(meeting), isNull);
      final cancelled = CapturePresentation.fromWire(
        jsonDecode(jsonEncode(app.captureState)),
      ).summary(meeting)!;
      expect(cancelled.phase, 'failed');
      expect(cancelled.cancelled, isTrue);
      expect(cancelled.active, isFalse);
      expect(cancelled.error, contains('cancelled'));
      expect(cancelled.preview, isEmpty);
    },
  );

  test(
    'transcript revision change at final token prevents late persistence',
    () async {
      runtime.beforeDone = () => store.transcript(
        meeting,
        'Corrected to Monday.',
        true,
        100,
        200,
        'remote',
      );
      await expectLater(app.generateSummary(meeting), throwsA(isA<RpcError>()));
      expect(store.meetingArtifacts(meeting, 'summary'), isEmpty);
      expect(store.sources, isEmpty);
    },
  );

  test(
    'disconnect liveness is checked while native generation is stalled',
    () async {
      var current = true;
      runtime.entered = Completer();
      runtime.release = Completer();
      final future = app.generateSummary(meeting, current: () => current);
      final rejected = expectLater(future, throwsA(isA<RpcError>()));
      await runtime.entered!.future;
      current = false;
      await rejected.timeout(const Duration(seconds: 3));
      expect(runtime.cancelled, isNotEmpty);
      expect(store.meetingArtifacts(meeting, 'summary'), isEmpty);
    },
  );

  test('cancel operation needs no ready helper', () async {
    runtime.entered = Completer();
    runtime.release = Completer();
    final future = app.generateSummary(meeting);
    final rejected = expectLater(future, throwsA(isA<RpcError>()));
    await runtime.entered!.future;
    await app.call('meetings.cancel_summary', {'id': meeting});
    await rejected;
    expect(store.summaryCheckpoint(meeting), isNull);
  });

  test(
    'summary commit rollback preserves earlier artifact on checkpoint failure',
    () async {
      await app.generateSummary(meeting);
      store.db.execute(
        "CREATE TRIGGER fail_checkpoint BEFORE INSERT ON meeting_summary_checkpoints BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      await expectLater(app.generateSummary(meeting), throwsA(anything));
      expect(store.meetingArtifacts(meeting, 'summary'), hasLength(1));
      expect(store.summaryCheckpoint(meeting), isNotNull);
    },
  );

  test(
    'derived source failure rolls back artifact and checkpoint together',
    () async {
      await app.generateSummary(meeting);
      final checkpoint = store.summaryCheckpoint(meeting);
      final source = store.sources.single;
      store.db.execute(
        "CREATE TRIGGER fail_summary_source BEFORE INSERT ON sources BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      await expectLater(app.generateSummary(meeting), throwsA(anything));
      expect(store.meetingArtifacts(meeting, 'summary'), hasLength(1));
      expect(store.summaryCheckpoint(meeting), checkpoint);
      expect(store.sources.single, source);
    },
  );

  test(
    'workspace clear cancels stalled generation and removes checkpoint and derived source',
    () async {
      await app.generateSummary(meeting);
      runtime.entered = Completer();
      runtime.release = Completer();
      final future = app.generateSummary(meeting);
      final rejected = expectLater(future, throwsA(isA<RpcError>()));
      await runtime.entered!.future;
      await app.call('workspace.clear', {});
      await rejected;
      expect(store.rows('SELECT * FROM meeting_summary_checkpoints'), isEmpty);
      expect(store.rows('SELECT * FROM artifacts'), isEmpty);
    },
  );
}
