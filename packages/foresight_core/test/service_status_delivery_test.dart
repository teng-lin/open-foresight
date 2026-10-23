import 'package:foresight_test_support/desktop_identity.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:foresight_core/desktop.dart'
    show
        DesktopPresentation,
        GenerationPresentationValue,
        CapturePresentation,
        GooglePresentation,
        GenerationPresentation;
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/read_models.dart';
import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/store_read_queries.dart';
import 'package:foresight_test_support/helper_adoption.dart';
import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class _HeldTimer implements Timer {
  _HeldTimer(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    if (!isActive) return;
    isActive = false;
    tick++;
    callback();
  }
}

class _StatusRag extends AdoptionRag {
  @override
  Future<IndexResponse> indexDocument(
    ServiceCall call,
    IndexRequest request,
  ) async => IndexResponse(success: true);
}

class _StreamingSummary extends NativeRuntime {
  _StreamingSummary()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  // Closed by each fixture after its terminal generation frame.
  // ignore: close_sinks
  final chunks = StreamController<Map<String, dynamic>>();
  final entered = Completer<void>();
  var _processedPreviews = 0;
  final _previewWaiters = <int, Completer<void>>{};

  Future<void> previewsProcessed(int count) => count <= _processedPreviews
      ? Future.value()
      : _previewWaiters.putIfAbsent(count, Completer<void>.new).future;

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
    entered.complete();
    await for (final event in chunks.stream) {
      yield event;
      // The coordinator asks for its next event only after handling this one.
      // Acknowledgment counts delivery, independently of the preview's value.
      if (event['type'] == 'preview') {
        _previewWaiters.remove(++_processedPreviews)?.complete();
      }
    }
  }

  @override
  bool cancel({String? requestId}) => true;
}

class _InterfaceGeneration extends _StreamingSummary {
  @override
  bool get generating => true;
}

void main() {
  late Directory root;
  late ProfilePaths profile;
  late ApplicationService service;
  late ServiceClient client;
  late Map<String, String> environment;
  final timers = <_HeldTimer>[];
  final snapshots = <Map<String, dynamic>>[];
  _HeldTimer getBroadcastTimer() => timers.lastWhere(
    (timer) =>
        timer.isActive && timer.delay == const Duration(milliseconds: 100),
  );

  setUp(() async {
    timers.clear();
    snapshots.clear();
    root = createTestTempDirectorySync('status-delivery-');
    profile = ProfilePaths('${root.path}/d', '${root.path}/r');
    privateDirectory(profile.data);
    privateDirectory(profile.runtime);
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment.removeWhere(
      (key, _) =>
          key.startsWith('FORESIGHT_') && key != 'FORESIGHT_SQLITE_LIBRARY',
    );
    addTearDown(() {
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
    });
    final helper = Server.create(
      services: [_StatusRag(), AdoptionControl(control.State())],
    );
    await helper.serve(
      address: InternetAddress(
        '${profile.runtime}/helper.sock',
        type: InternetAddressType.unix,
      ),
      port: 0,
    );
    addTearDown(helper.shutdown);
    service = await ApplicationService.start(
      profile,
      desktopPeerVerifier: trustInProcessDesktop,
      clock: Clock.fixed(DateTime.utc(2026, 10, 22)),
      createTimer: (delay, callback) {
        final timer = _HeldTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(service.close);
    await service.ready;
    client = await ServiceClient.connect(service.path);
    addTearDown(client.close);
    final events = client.events.stream.listen((event) {
      if (event['event'] == 'changed') snapshots.add(event);
    });
    addTearDown(events.cancel);
    await client.call('security.attach_desktop', {
      'visible': true,
      'token': File('${profile.data}/.desktop-capability').readAsStringSync(),
    });
  });

  test('typed desktop values decode real service producer JSON', () async {
    final application = service.application;
    application.provisionalTranscript['microphone'] = 'Live text';
    final runtime = _StreamingSummary();
    service.domain.generator = runtime;
    addTearDown(() async {
      final drained = runtime.chunks.stream.drain<void>();
      await runtime.chunks.close();
      await drained;
      runtime.close();
    });
    final remote = await RemoteDomain.connect(profile);
    addTearDown(() async {
      remote.close();
      await remote.closed;
    });
    final wire = jsonDecode(jsonEncode(await client.call('status'))) as Map;
    final capture = CapturePresentation.fromWire(wire['capture']);
    expect(capture, CapturePresentation.fromWire(application.captureState));
    expect(capture.provisional['microphone'], 'Live text');
    expect(capture.echoCancellation.requested, isFalse);
    expect(capture.questionDetector.configured, isFalse);
    expect(capture.proactive.stage, 'idle');
    expect(remote.capturePresentation, capture);
    final google = GooglePresentation.fromWire(wire['google']);
    expect(google, GooglePresentation.fromWire(application.googleState));
    expect(remote.googlePresentation, google);
    expect(google.connected, isFalse);
    expect(google.accounts, isEmpty);
    expect(
      remote.generator!.presentation,
      GenerationPresentation.fromWire(wire['generation']),
    );
    // NativeRuntime.effectiveState has no 'generating' key: the interface
    // supplies that fact for both production and desktop test runtimes.
    final local = _InterfaceGeneration();
    addTearDown(() async {
      final drained = local.chunks.stream.drain<void>();
      await local.chunks.close();
      await drained;
      local.close();
    });
    expect(local.effectiveState.containsKey('generating'), isFalse);
    expect(local.presentation.generating, isTrue);
  });

  test(
    'recording state precedes start, pause, resume and stop replies',
    () async {
      final library =
          '${root.path}/recording.${Platform.isMacOS ? 'dylib' : 'so'}';
      await buildCachedNativeFixture(
        source: 'test/fixtures/recording_native_stub.cpp',
        output: library,
      );
      runtimeConfiguration.environment['FORESIGHT_NATIVE'] = library;
      final store = service.domain.store;
      store.setPreference('liveEnhance', 'false');
      final model = File('${root.path}/speech')
        ..writeAsStringSync('ABI fixture');
      await store.register('speech', model.path, '/usr/bin/true');
      final meeting = store.meeting('Recording');
      for (final entry in [
        ('meetings.start', true, false),
        ('meetings.pause', true, true),
        ('meetings.resume', true, false),
        ('meetings.stop', false, false),
      ]) {
        snapshots.clear();
        service.application.changed();
        await Future<void>.delayed(Duration.zero);
        final pending = getBroadcastTimer();
        await client.call(entry.$1, {
          'id': meeting,
          'workspace_epoch': store.workspaceEpoch,
        });
        expect(
          snapshots,
          isNotEmpty,
          reason: '${entry.$1}: event before reply',
        );
        final capture = snapshots.last['capture'] as Map;
        expect(capture['active'], entry.$2);
        expect(capture['paused'], entry.$3);
        expect(pending.isActive, isFalse);
      }
    },
  );

  test(
    'failed commands flush their latest state before the error reply',
    () async {
      service.application.recordingState = 'pending failure state';
      service.application.changed();
      await Future<void>.delayed(Duration.zero);
      final pending = getBroadcastTimer();
      await expectLater(
        client.call('meetings.pause', {
          'id': 999,
          'workspace_epoch': service.domain.store.workspaceEpoch,
        }),
        throwsA(isA<RpcError>()),
      );
      expect(pending.isActive, isFalse);
      expect(
        (snapshots.last['capture'] as Map)['state'],
        'pending failure state',
      );
    },
  );

  test('a committed command flushes before its held reply gate', () async {
    final gates = Directory('${root.path}/gates')..createSync();
    const point = 'request.committed.notes.save';
    File('${gates.path}/$point.hold').writeAsStringSync('');
    runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] = gates.path;
    var replied = false;
    final work = client.call('notes.save', {'title': 'Saved', 'body': 'Body'});
    unawaited(work.then<void>((_) => replied = true, onError: (Object _) {}));
    try {
      await eventually(() => File('${gates.path}/$point.reached').existsSync());
      await eventually(() => snapshots.isNotEmpty);
      expect(snapshots.last['revision'], service.domain.store.dataRevision);
      expect(replied, isFalse);
    } finally {
      File('${gates.path}/$point.release').writeAsStringSync('');
    }
    await work;
  });

  for (final fails in [false, true]) {
    test(
      'service streams flush before terminal ${fails ? 'error' : 'done'} only',
      () async {
        service.application.recordingState = 'stream terminal state';
        service.application.changed();
        await Future<void>.delayed(Duration.zero);
        final pending = getBroadcastTimer();
        var values = 0;
        final finished = Completer<void>();
        final subscription = client
            .stream('answer.stream', {
              'question': 'What next?',
              if (fails) 'meeting_id': 999,
            })
            .listen(
              (value) {
                values++;
                expect(
                  snapshots,
                  isEmpty,
                  reason: 'progress frames do not force a flush',
                );
              },
              onError: (Object error) {
                expect(fails, isTrue);
                expect(error, isA<RpcError>());
                expect(
                  (snapshots.last['capture'] as Map)['state'],
                  'stream terminal state',
                );
                finished.complete();
              },
              onDone: () {
                if (fails) return;
                expect(
                  (snapshots.last['capture'] as Map)['state'],
                  'stream terminal state',
                );
                finished.complete();
              },
            );
        addTearDown(subscription.cancel);
        await finished.future;
        expect(pending.isActive, isFalse);
        expect(values, fails ? 0 : 1);
      },
    );
  }

  test(
    'bootstrap handlers preserve their no-status response behavior',
    () async {
      service.application.changed();
      await Future<void>.delayed(Duration.zero);
      final pending = getBroadcastTimer();
      await client.call('security.allow_import_root', {'path': root.path});
      expect(pending.isActive, isTrue);
      expect(snapshots, isEmpty);
    },
  );

  test(
    'summary broadcasts retain latest preview and retire settled bodies through RemoteDomain',
    () async {
      final store = service.domain.store;
      store.setPreference('liveEnhance', 'false');
      final meeting = store.meeting('Summary');
      store.transcript(
        meeting,
        'Alice owns release on Friday.',
        true,
        0,
        100,
        'microphone',
      );
      final runtime = _StreamingSummary();
      service.domain.generator = runtime;
      addTearDown(() async {
        await runtime.chunks.close();
        runtime.close();
      });
      final remote = await RemoteDomain.connect(profile);
      addTearDown(() async {
        remote.close();
        await remote.closed;
      });
      var changes = 0;
      final notifications = remote.changes.listen((_) => changes++);
      addTearDown(notifications.cancel);
      final work = client.call('meetings.generate', {
        'id': meeting,
        'kind': 'summary',
        'workspace_epoch': store.workspaceEpoch,
      });
      await runtime.entered.future;
      for (var i = 0; i < 201; i++) {
        runtime.chunks.add({
          'type': 'preview',
          'text': '# Overview\nPreview $i',
        });
      }
      Map state() =>
          (service.application.captureState['meeting_summaries']
                  as Map)['$meeting']
              as Map;
      Map remoteState() =>
          (remote.capture['meeting_summaries'] as Map)['$meeting'] as Map;
      await runtime.previewsProcessed(201);
      expect(state()['preview'], '# Overview\nPreview 200');
      expect(snapshots, isEmpty);
      expect(
        timers.where(
          (timer) =>
              timer.isActive &&
              timer.delay == const Duration(milliseconds: 100),
        ),
        hasLength(1),
      );
      final first = getBroadcastTimer();
      first.fire();
      await eventually(() => changes == 1);
      expect(remoteState()['preview'], '# Overview\nPreview 200');
      final activeWire =
          jsonDecode(jsonEncode(await client.call('status'))) as Map;
      final active = CapturePresentation.fromWire(
        activeWire['capture'],
      ).summary(meeting)!;
      expect(active.active, isTrue);
      expect(active.phase, 'summarizing');
      expect(active.preview, '# Overview\nPreview 200');
      expect(remote.capturePresentation.summary(meeting), active);
      expect(snapshots, hasLength(1));
      runtime.chunks.add({
        'type': 'preview',
        'text': '# Overview\nLatest preview',
      });
      await runtime.previewsProcessed(202);
      expect(state()['preview'], '# Overview\nLatest preview');
      getBroadcastTimer().fire();
      await eventually(() => changes == 2);
      expect(remoteState()['preview'], '# Overview\nLatest preview');
      service.application.changed();
      await Future<void>.delayed(Duration.zero);
      getBroadcastTimer().fire();
      await eventually(() => snapshots.length == 3);
      expect(
        changes,
        2,
        reason: 'identical delivered snapshots are deduplicated',
      );
      runtime.chunks.add({
        'type': 'delta',
        'text': '# Overview\nFinished summary.',
      });
      runtime.chunks.add({'type': 'done', 'status': 'completed'});
      await runtime.chunks.close();
      await work;
      await eventually(() => changes == 3);
      final settledWire =
          jsonDecode(jsonEncode(await client.call('status'))) as Map;
      final settled = CapturePresentation.fromWire(
        settledWire['capture'],
      ).summary(meeting)!;
      expect(settled.phase, 'completed');
      expect(settled.active, isFalse);
      expect(settled.preview, isEmpty);
      expect(remote.capturePresentation.summary(meeting), settled);
      expect(remoteState()['active'], isFalse);
      expect(remoteState().containsKey('preview'), isFalse);
      expect(
        (snapshots.last['capture'] as Map)['meeting_summaries']['$meeting']
            .containsKey('preview'),
        isFalse,
      );
    },
  );

  test(
    'presentation changes do not refresh readers; committed data does',
    () async {
      final store = service.domain.store;
      final remote = await RemoteDomain.connect(profile);
      addTearDown(() async {
        remote.close();
        await remote.closed;
      });
      final results = <ReadResult<List<SourceSummary>>>[];
      final watcher = remote.store
          .watch(StoreReadQueries.sources())
          .listen(results.add);
      addTearDown(watcher.cancel);
      await eventually(() => results.any((result) => result.current));
      final originalReads = results.length;
      var changes = 0;
      final notifications = remote.changes.listen((_) => changes++);
      addTearDown(notifications.cancel);
      for (var i = 0; i < 4; i++) {
        service.application.provisionalTranscript['microphone'] = 'draft $i';
        service.application.changed();
        await Future<void>.delayed(Duration.zero);
        getBroadcastTimer().fire();
        await eventually(() => changes == i + 1);
      }
      expect(results, hasLength(originalReads));
      final before = store.dataRevision;
      final source = store.importText(
        'Committed source',
        'body',
        'text/plain',
        'fixture',
      );
      service.application.changed();
      await Future<void>.delayed(Duration.zero);
      getBroadcastTimer().fire();
      await eventually(
        () => results.any(
          (result) => result.value?.any((row) => row.id == source) ?? false,
        ),
      );
      expect(snapshots.last['revision'], store.dataRevision);
      expect(snapshots.last['revision'], isNot(before));
    },
  );

  test(
    'committed writes to every application table advance the next event revision',
    () async {
      final store = service.domain.store;
      // Cover every persistence table, including all desktop projection inputs.
      // Keeping this inventory exact makes a new table require revision evidence.
      final inserts = <String, String>{
        'sources':
            "INSERT INTO sources(id,title,content,mime,revision,state,provenance) VALUES('s','Source','Body','text/plain',1,'imported','fixture')",
        'source_details':
            "INSERT INTO source_details(source_id,imported,changed) VALUES('s',1,1)",
        'notes': "INSERT INTO notes(id,title,body) VALUES(1,'Note','Body')",
        'answers':
            "INSERT INTO answers(id,question,body,status,citations,model,created) VALUES(1,'Question','Answer','answered','[]','none',1)",
        'models':
            "INSERT INTO models(kind,path,digest,runtime) VALUES('embedding','/fixture','digest','/fixture')",
        'meetings':
            "INSERT INTO meetings(id,title,state) VALUES(1,'Meeting','completed')",
        'transcript':
            "INSERT INTO transcript(id,meeting_id,text,final,start_ms,end_ms,source) VALUES(1,1,'Transcript',1,0,1,'fixture')",
        'artifacts':
            "INSERT INTO artifacts(id,meeting_id,kind,generated,input_revision,model,prompt_version) VALUES(1,1,'summary','Summary',0,'none','v1')",
        'preferences':
            "INSERT INTO preferences(key,value) VALUES('revision-fixture','1')",
        'conversation_memory':
            "INSERT INTO conversation_memory(conversation,through_answer_id,messages) VALUES('fixture',1,'[]')",
        'document_labels':
            "INSERT INTO document_labels(document_id,label_name,label_source) VALUES('s','Label','manual')",
        'document_clusters':
            "INSERT INTO document_clusters(cluster_id,label) VALUES(1,'Cluster')",
        'graph_documents':
            "INSERT INTO graph_documents(model_identity,document_id,source_revision,embedding,proj_x,proj_y,proj_z,updated) VALUES('model','s',1,X'00',0,0,0,1)",
        'graph_layouts':
            "INSERT INTO graph_layouts(model_identity,document_set) VALUES('model','[]')",
        'graph_force_state':
            "INSERT INTO graph_force_state(model_identity,label_set) VALUES('model','[]')",
        'meeting_details':
            'INSERT INTO meeting_details(meeting_id,created) VALUES(1,1)',
        'meeting_notes':
            "INSERT INTO meeting_notes(meeting_id,body) VALUES(1,'Notes')",
        'meeting_note_events':
            "INSERT INTO meeting_note_events(id,meeting_id,event_key,title) VALUES(1,1,'event','Event')",
        'meeting_answers':
            'INSERT INTO meeting_answers(meeting_id,answer_id) VALUES(1,1)',
        'meeting_question_cursors':
            'INSERT INTO meeting_question_cursors(meeting_id,transcript_id) VALUES(1,1)',
        'meeting_questions':
            "INSERT INTO meeting_questions(id,meeting_id,transcript_id,question,normalized,created) VALUES(1,1,1,'Question?','question',1)",
        'google_sources':
            "INSERT INTO google_sources(source_id,account,file_id,modified,mime) VALUES('s','account','file','now','text/plain')",
        'calendar_events':
            "INSERT INTO calendar_events(event_key,account,calendar_id,google_id,meeting_id,source_id,starts,ends,status,metadata,synced) VALUES('event','account','calendar','google',1,'s',0,1,'confirmed','{}',1)",
        'google_folders':
            "INSERT INTO google_folders(account,folder_id) VALUES('account','folder')",
        'pending_helper_deletes':
            "INSERT INTO pending_helper_deletes(document_id,queued_at) VALUES('deleted',1)",
        'request_keys':
            "INSERT INTO request_keys(key,operation,arguments,result,created) VALUES('request','notes.save','{}','null',1)",
        'meeting_summary_checkpoints':
            "INSERT INTO meeting_summary_checkpoints(meeting_id,artifact_id,input_length,input_digest,identity) VALUES(1,1,1,'digest','identity')",
        'meeting_tasks':
            "INSERT INTO meeting_tasks(id,meeting_id,task_key,task,status,evidence,input_revision) VALUES(1,1,'task','Task','open','[]',0)",
        'document_summary_cache':
            "INSERT INTO document_summary_cache(cache_key,source_id,source_revision,body,identity) VALUES('cache','s',1,'Body','identity')",
      };
      final tables = store
          .rows(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
          )
          .map((row) => row['name'] as String)
          .toSet();
      expect(inserts.keys.toSet(), tables);
      final otherWriter = Store(store.path);
      addTearDown(otherWriter.close);
      for (final entry in inserts.entries) {
        final before = store.dataRevision;
        store.db.execute('BEGIN IMMEDIATE');
        store.db.execute(entry.value);
        store.db.execute('COMMIT');
        final after = store.dataRevision;
        expect(after, isNot(before), reason: '${entry.key}: service writer');
        service.application.changed();
        await Future<void>.delayed(Duration.zero);
        getBroadcastTimer().fire();
        await eventually(() => snapshots.lastOrNull?['revision'] == after);
        // Writes through another connection advance data_version even when the
        // service connection's total_changes counter does not move.
        final column =
            store.rows('PRAGMA table_info("${entry.key}")').first['name']
                as String;
        otherWriter.db.execute('BEGIN IMMEDIATE');
        otherWriter.db.execute('UPDATE "${entry.key}" SET "$column"="$column"');
        otherWriter.db.execute('COMMIT');
        final external = store.dataRevision;
        expect(external, isNot(after), reason: '${entry.key}: external writer');
        service.application.changed();
        await Future<void>.delayed(Duration.zero);
        getBroadcastTimer().fire();
        await eventually(() => snapshots.lastOrNull?['revision'] == external);
      }
    },
  );

  test('workspace replacement bypasses the held broadcast timer', () async {
    service.application.changed();
    await Future<void>.delayed(Duration.zero);
    final pending = getBroadcastTimer();
    final before = service.domain.store.workspaceEpoch;
    service.domain.store.renewWorkspaceEpoch();
    service.application.changed();
    await eventually(() => snapshots.isNotEmpty);
    expect(pending.isActive, isFalse);
    expect(snapshots.last['workspace_epoch'], isNot(before));
  });

  test('close cancels the pending broadcast', () async {
    service.application.changed();
    await Future<void>.delayed(Duration.zero);
    final pending = getBroadcastTimer();
    await service.close();
    expect(pending.isActive, isFalse);
  });
}
