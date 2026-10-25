import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/desktop.dart'
    show CapturePresentation, MeetingRunPresentation;
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/meeting_preparation.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class WorkflowRuntime extends NativeRuntime {
  WorkflowRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final calls = <String>[], cancelled = <String>[];
  final prompts = <String>[];
  Completer<void>? entered, release;
  int? failCall;
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
    calls.add(id);
    prompts.add(prompt);
    if (entered?.isCompleted == false) entered!.complete();
    await release?.future;
    String body;
    if (systemPrompt.contains('Extract explicit meeting commitments')) {
      final evidence = ((jsonDecode(prompt) as Map)['evidence'] as List)
          .cast<Map>();
      body = jsonEncode({
        'tasks': [
          for (final item in evidence)
            if ((item['text'] as String).contains('Alice will ship Friday.'))
              {
                'task': 'Ship release',
                'owner': 'Alice',
                'due': 'Friday',
                'state': 'open',
                'evidence': [
                  {'id': item['id'], 'quote': 'Alice will ship Friday.'},
                ],
              },
        ],
      });
    } else {
      body = 'Document fact: launch Friday.';
    }
    yield {'type': 'preview', 'text': body};
    yield {'type': 'delta', 'text': body};
    beforeDone?.call();
    yield {
      'type': 'done',
      'status': failCall == calls.length ? 'failed' : 'completed',
    };
  }

  @override
  bool cancel({String? requestId}) {
    if (requestId != null) cancelled.add(requestId);
    if (release?.isCompleted == false) release!.complete();
    return true;
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late Store store;
  late Helper helper;
  late AdapterDomain domain;
  late Application app;
  late WorkflowRuntime runtime;
  late int meeting;
  setUp(() {
    root = createTestTempDirectorySync('workflows-');
    store = Store('${root.path}/app.db');
    helper = Helper(
      '${root.path}/helper.sock',
      '${root.path}/rag',
      manageProcess: false,
    );
    domain = AdapterDomain(store, helper);
    runtime = WorkflowRuntime();
    domain.generator = runtime;
    app = Application(domain);
    store.setPreference('liveEnhance', 'false');
    meeting = store.meeting('Launch');
    store.transcript(
      meeting,
      'Alice will ship Friday.',
      true,
      0,
      100,
      'microphone',
    );
    addTearDown(() async {
      await app.close();
      domain.close();
      runtime.close();
      await helper.close();
      store.close();
      root.deleteSync(recursive: true);
    });
  });
  test(
    'both action aliases share one typed artifact and preserve manual edits',
    () async {
      await app.generateMeeting(meeting, 'action_items');
      expect(
        (app.captureState['meeting_workflows'] as Map)['$meeting:actions'],
        allOf(containsPair('active', false), isNot(contains('preview'))),
      );
      expect(store.meetingArtifacts(meeting, 'action_items'), isEmpty);
      final task = store.meetingTasks(meeting).single;
      await app.call('meetings.edit_task', {
        'id': task['id'],
        'task': 'Reviewed task',
        'owner': null,
        'due': null,
        'status': 'completed',
      });
      await app.generateMeeting(meeting, 'actions');
      final updated = store.meetingTasks(meeting).single;
      expect(updated['task'], 'Reviewed task');
      expect(updated['status'], 'completed');
      expect(updated['owner'], isNull);
      expect(updated['manual'], 1);
      await app.call('meetings.edit_task', {
        'id': task['id'],
        'owner': 'Reviewer',
      });
      expect(store.meetingTasks(meeting).single['owner'], 'Reviewer');
      expect(store.meetingTasks(meeting).single['task'], 'Reviewed task');
      expect(store.meetingArtifacts(meeting, 'actions'), hasLength(2));
      expect(
        store.rows('SELECT content FROM sources WHERE id=?', [
          'meeting-actions-$meeting',
        ]).single['content'],
        contains('Reviewed task'),
      );
    },
  );
  test(
    'failed extraction and task-store failure keep prior artifacts and tasks',
    () async {
      await app.generateActions(meeting);
      final before = store.meetingTasks(meeting);
      runtime.failCall = 2;
      await expectLater(app.generateActions(meeting), throwsStateError);
      expect(store.meetingTasks(meeting), before);
      final failed = CapturePresentation.fromWire(
        jsonDecode(jsonEncode(app.captureState)),
      ).workflow(meeting, 'actions')!;
      expect(failed.phase, 'failed');
      expect(failed.error, contains('Meeting generation failed'));
      expect(failed.active, isFalse);
      expect(failed.cancelled, isFalse);
      expect(failed.preview, isEmpty);
      runtime.failCall = null;
      store.db.execute(
        "CREATE TRIGGER fail_tasks BEFORE INSERT ON meeting_tasks BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      await expectLater(app.generateActions(meeting), throwsA(anything));
      expect(store.meetingTasks(meeting), before);
      expect(store.meetingArtifacts(meeting, 'actions'), hasLength(1));
    },
  );
  test('raw note revision at final token rejects late action commit', () async {
    runtime.beforeDone = () => store.saveMeetingNotes(meeting, 'Changed note');
    await expectLater(app.generateActions(meeting), throwsA(isA<RpcError>()));
    expect(store.meetingTasks(meeting), isEmpty);
  });
  test(
    'parent cancellation reaches a stalled child; peer cannot cancel it',
    () async {
      runtime.entered = Completer();
      runtime.release = Completer();
      final work = app.generateActions(meeting, requestId: 'parent');
      final failed = expectLater(work, throwsA(isA<RpcError>()));
      await runtime.entered!.future;
      expect(app.cancelMeetingWorkflowRequest('peer'), isFalse);
      expect(app.cancelMeetingWorkflowRequest('parent'), isTrue);
      await failed;
      expect(runtime.cancelled, contains('parent-actions-1'));
      expect(store.meetingTasks(meeting), isEmpty);
      final cancelled = CapturePresentation.fromWire(
        jsonDecode(jsonEncode(app.captureState)),
      ).workflow(meeting, 'actions')!;
      expect(cancelled.phase, 'failed');
      expect(cancelled.cancelled, isTrue);
      expect(cancelled.active, isFalse);
      expect(cancelled.error, contains('cancelled'));
      expect(cancelled.preview, isEmpty);
    },
  );
  test(
    'missing/null or other-kind cancellation leaves withheld action producer active',
    () async {
      runtime.entered = Completer();
      runtime.release = Completer();
      final work = app.generateActions(meeting, requestId: 'owned-actions');
      final settled = expectLater(
        work,
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.cancelled,
          ),
        ),
      );
      await runtime.entered!.future;
      for (final arguments in <Map<String, dynamic>>[
        {'id': meeting},
        {'id': meeting, 'kind': null},
        {'id': meeting, 'kind': 'preparation'},
      ]) {
        expect(await app.call('meetings.cancel_generation', arguments), isNull);
        expect(runtime.cancelled, isEmpty);
        expect(runtime.release!.isCompleted, isFalse);
      }
      await app.call('meetings.cancel_generation', {
        'id': meeting,
        'kind': 'actions',
      });
      await settled;
      expect(runtime.cancelled, contains('owned-actions-actions-1'));
      expect(store.meetingTasks(meeting), isEmpty);
    },
  );
  test(
    'document passthrough, shared cache, event reuse and revision invalidation',
    () async {
      final source = store.importText(
        'Design',
        'Document content ' * 70,
        'text/plain',
        'fixture',
      );
      await app.prepareMeeting(meeting, [source]);
      final count = runtime.calls.length;
      await app.prepareMeeting(meeting, [source]);
      expect(runtime.calls, hasLength(count));
      final other = store.meeting('Another event');
      await app.prepareMeeting(other, [source]);
      expect(runtime.calls, hasLength(count));
      store.importText(
        'Design',
        'Revised document content ' * 50,
        'text/plain',
        'fixture',
        id: source,
      );
      await app.prepareMeeting(meeting, [source]);
      expect(runtime.calls.length, greaterThan(count));
      expect(store.meetingArtifacts(meeting, 'preparation'), hasLength(2));
    },
  );
  test(
    'soft deletion retains old cache bytes but refuses reuse until workspace clear',
    () async {
      final source = store.importText(
        'Design',
        'Document content ' * 70,
        'text/plain',
        'fixture',
      );
      await app.prepareMeeting(meeting, [source]);
      final cached = store.rows('SELECT * FROM document_summary_cache');
      expect(cached, isNotEmpty);
      final calls = runtime.calls.length;
      store.tombstone(source);
      expect(store.rows('SELECT * FROM document_summary_cache'), cached);
      await expectLater(
        app.prepareMeeting(meeting, [source]),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.notFound,
          ),
        ),
      );
      expect(runtime.calls, hasLength(calls));
      expect(store.rows('SELECT * FROM document_summary_cache'), cached);
      await app.call('workspace.clear', {});
      expect(store.rows('SELECT * FROM document_summary_cache'), isEmpty);
    },
  );
  test(
    'changed or deleted preparation input cannot commit after its final token',
    () async {
      final source = store.importText(
        'Design',
        'Content ' * 80,
        'text/plain',
        'fixture',
      );
      runtime.beforeDone = () => store.tombstone(source);
      await expectLater(
        app.prepareMeeting(meeting, [source]),
        throwsA(isA<RpcError>()),
      );
      expect(store.meetingArtifacts(meeting, 'preparation'), isEmpty);
      expect(store.rows('SELECT * FROM document_summary_cache'), isEmpty);
    },
  );
  test(
    'partial document failure is disclosed and an all-failed retry preserves history',
    () async {
      final a = store.importText(
        'A',
        'Content A ' * 50,
        'text/plain',
        'fixture',
      );
      final b = store.importText(
        'B',
        'Content B ' * 50,
        'text/plain',
        'fixture',
      );
      runtime.failCall = 1;
      await app.prepareMeeting(meeting, [a, b]);
      final artifact = store.meetingArtifacts(meeting, 'preparation').single;
      expect(
        (jsonDecode(artifact['manifest'] as String) as Map)['degraded'],
        isTrue,
      );
      expect(artifact['generated'], contains('Unavailable documents'));
      runtime.failCall = runtime.calls.length + 1;
      await expectLater(app.prepareMeeting(meeting, [a]), throwsStateError);
      expect(store.meetingArtifacts(meeting, 'preparation'), hasLength(1));
    },
  );
  test(
    'retrying degraded preparation regenerates only failed documents',
    () async {
      final a = store.importText(
        'A',
        'Content A ' * 50,
        'text/plain',
        'fixture',
      );
      final b = store.importText(
        'B',
        'Content B ' * 50,
        'text/plain',
        'fixture',
      );
      runtime.failCall = 1;
      await app.prepareMeeting(meeting, [a, b]);
      expect(store.rows('SELECT * FROM document_summary_cache'), hasLength(1));
      final before = runtime.prompts.length;
      runtime.failCall = null;
      await app.prepareMeeting(meeting, [a, b]);
      final retried = runtime.prompts.skip(before).toList();
      expect(retried, hasLength(2)); // Failed document, then combined brief.
      expect(retried.first, startsWith(documentMapPrefix));
      expect(retried.first, contains('Content A'));
      expect(retried.first, isNot(contains('Content B')));
      expect(retried.last, startsWith(preparationSynthesisInstructions));
      expect(store.rows('SELECT * FROM document_summary_cache'), hasLength(2));
      final versions = store.meetingArtifacts(meeting, 'preparation');
      expect(versions, hasLength(2));
      expect(
        (jsonDecode(versions.first['manifest'] as String) as Map)['degraded'],
        isFalse,
      );
      expect(
        versions.first['generated'],
        isNot(contains('Unavailable documents')),
      );
      final completed = runtime.calls.length;
      await app.prepareMeeting(meeting, [a, b]);
      expect(runtime.calls, hasLength(completed));
      expect(store.meetingArtifacts(meeting, 'preparation'), hasLength(2));
    },
  );
  test(
    'typed preparation JSON retains document progress and synthesis preview',
    () async {
      final long = store.importText(
        'Design',
        'Document content ' * 300,
        'text/plain',
        'fixture',
      );
      final short = store.importText(
        'Schedule',
        'Launch Friday.',
        'text/plain',
        'fixture',
      );
      final states = <MeetingRunPresentation>[];
      final changes = app.changes.stream.listen((_) {
        final capture = CapturePresentation.fromWire(
          jsonDecode(jsonEncode(app.captureState)),
        );
        final preparation = capture.workflow(meeting, 'preparation');
        if (preparation != null) states.add(preparation);
      });
      addTearDown(changes.cancel);
      await app.prepareMeeting(meeting, [long, short]);
      final documents = states.firstWhere(
        (state) =>
            state.active && state.phase == 'documents' && state.completed > 0,
      );
      expect(documents.total, greaterThan(1));
      final synthesis = states.firstWhere(
        (state) =>
            state.active &&
            state.phase == 'synthesizing' &&
            state.preview.isNotEmpty,
      );
      expect(synthesis.preview, 'Document fact: launch Friday.');
      final settled = CapturePresentation.fromWire(
        jsonDecode(jsonEncode(app.captureState)),
      ).workflow(meeting, 'preparation')!;
      expect(settled.phase, 'completed');
      expect(settled.active, isFalse);
      expect(settled.preview, isEmpty);
      expect(store.meetingArtifacts(meeting, 'preparation'), hasLength(1));
    },
  );

  test(
    'empty and short documents avoid inference; Unicode windows retain end evidence',
    () async {
      final empty = await summarizePreparationDocument(
        '',
        complete: (_, __, ___) async => fail('no model'),
        checkCurrent: () {},
        onProgress: (_) {},
      );
      expect(empty.body, '');
      final short = await summarizePreparationDocument(
        '  short fact  ',
        complete: (_, __, ___) async => fail('no model'),
        checkCurrent: () {},
        onProgress: (_) {},
      );
      expect(short.body, 'short fact');
      final windows = workflowTextWindows('${'中文😀 ' * 1000}FINAL', 512);
      expect(windows.last, endsWith('FINAL'));
      expect(utf8.decode(utf8.encode(windows.join())), windows.join());
    },
  );
  test(
    'latest artifact edits refresh search; historical edits retain current source',
    () async {
      store.artifact(meeting, 'summary', 'Brief', 'fixture');
      final old = store.meetingArtifacts(meeting, 'summary').single;
      store.artifact(meeting, 'summary', 'Brief', 'fixture');
      final latest = store.meetingArtifacts(meeting, 'summary').first;
      await app.call('artifacts.edit', {
        'id': latest['id'],
        'text': 'Reviewed current output',
      });
      await app.call('artifacts.edit', {
        'id': old['id'],
        'text': 'Historical correction',
      });
      expect(
        store.rows('SELECT content FROM sources WHERE id=?', [
          'meeting-summary-$meeting',
        ]).single['content'],
        'Reviewed current output',
      );
    },
  );
  test(
    'workspace clear removes tasks, document caches and source selections',
    () async {
      await app.generateActions(meeting);
      store.setPreference(
        'answerSources.meeting:$meeting',
        '["private-source"]',
      );
      await app.call('workspace.clear', {});
      expect(store.meetingTasks(meeting), isEmpty);
      expect(store.rows('SELECT * FROM document_summary_cache'), isEmpty);
      expect(store.preference('answerSources.meeting:$meeting'), '');
    },
  );
}
