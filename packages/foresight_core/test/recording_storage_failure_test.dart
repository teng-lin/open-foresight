import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/application_services/audio_saved_work.dart';
import 'package:foresight_core/src/application_services/audio_recognition_scheduler.dart';
import 'package:foresight_core/src/application_services/native_audio_recognition.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/generated/transcript_index.pb.dart'
    as transcript;
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/desktop_identity.dart';
import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'fixtures/durable_capture_routes.dart';

Future<void> _freshBoundaryProcess(String label, String name) async {
  // Keep process proof and both pipes even after a failed parent test teardown.
  final output = shortTestTempRoot.createTempSync('capture-boundary-child-');
  final events = File('${output.path}/events.jsonl');
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'test',
      'test/recording_storage_failure_test.dart',
      '--plain-name',
      name,
      '--reporter',
      'expanded',
      '--file-reporter=json:${events.path}',
    ],
    environment: {
      ...Platform.environment,
      'FORESIGHT_TEST_CAPTURE_BOUNDARY_CHILD': label,
      'FORESIGHT_TEST_CAPTURE_BOUNDARY_EVIDENCE': output.path,
    },
  );
  final stdout = StringBuffer(), stderr = StringBuffer();
  final outDone = Completer<void>(), errDone = Completer<void>();
  void finish(Completer<void> done) {
    if (!done.isCompleted) done.complete();
  }

  Object? pipeError;
  final outSubscription = process.stdout
      .transform(utf8.decoder)
      .listen(
        stdout.write,
        onDone: () => finish(outDone),
        onError: (Object error) {
          pipeError = error;
          finish(outDone);
        },
        cancelOnError: true,
      );
  final errSubscription = process.stderr
      .transform(utf8.decoder)
      .listen(
        stderr.write,
        onDone: () => finish(errDone),
        onError: (Object error) {
          pipeError = error;
          finish(errDone);
        },
        cancelOnError: true,
      );
  final elapsed = Stopwatch()..start();
  Duration remaining() {
    final budget = const Duration(seconds: 20) - elapsed.elapsed;
    return budget > Duration.zero ? budget : Duration.zero;
  }

  int? code;
  try {
    // This is inside the unchanged parent test budget. Reap before returning;
    // a native mapping's sealed environment cannot be reset by another isolate.
    code = await process.exitCode.timeout(remaining());
    await Future.wait([outDone.future, errDone.future]).timeout(remaining());
  } finally {
    try {
      if (code == null) process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 2));
      await Future.wait([
        outSubscription.cancel(),
        errSubscription.cancel(),
      ]).timeout(const Duration(seconds: 2));
    } finally {
      await File('${output.path}/stdout.log').writeAsString(stdout.toString());
      await File('${output.path}/stderr.log').writeAsString(stderr.toString());
    }
  }
  final report = '$stdout\n$stderr\nEvidence: ${output.path}';
  expect(code, 0, reason: report);
  expect(pipeError, isNull, reason: report);
  final inputs =
      jsonDecode(File('${output.path}/inputs.json').readAsStringSync()) as Map;
  expect(
    inputs['pid'],
    isNot(pid),
    reason: 'Native globals require a fresh OS process',
  );
  for (final key in [
    'FORESIGHT_NATIVE_LIBRARY',
    'FORESIGHT_TEST_SQL_SUPPORT_LIBRARY',
    'FORESIGHT_SQLITE_LIBRARY',
  ]) {
    expect(inputs[key], Platform.environment[key], reason: report);
  }
  final records = events
      .readAsLinesSync()
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList();
  final completed = records.where(
    (event) => event['type'] == 'testDone' && event['hidden'] != true,
  );
  expect(completed, hasLength(1), reason: report);
  expect(completed.single['result'], 'success', reason: report);
  expect(completed.single['skipped'], false, reason: report);
  expect(records.last['type'], 'done', reason: report);
  expect(records.last['success'], true, reason: report);
  print('Capture boundary $label: one child pass, zero skips; ${output.path}');
}

final class HeldIndexDomain extends AdapterDomain {
  HeldIndexDomain(super.store, super.helper, {super.createTimer});
  final entered = Completer<void>(), release = Completer<void>();
  final cancelled = Completer<void>(), cleanup = Completer<void>();
  bool hold = false, reject = false, holdCancellationCleanup = false;
  Future<void> waitForRelease(bool Function()? current) async {
    if (!hold) return;
    if (!entered.isCompleted) entered.complete();
    final watch = whenCancelled(() => !closed && (current?.call() ?? true));
    try {
      await Future.any([release.future, watch.future]);
    } catch (_) {
      if (!cancelled.isCompleted) cancelled.complete();
      if (holdCancellationCleanup) await cleanup.future;
      rethrow;
    } finally {
      watch.dispose();
    }
  }

  @override
  Future<void> index(String id, {bool Function()? current}) async {
    await waitForRelease(current);
    if (reject) throw StateError('controlled index failure');
    await super.index(id, current: current);
  }

  @override
  Future<transcript.TranscriptDeltaResult> applyTranscriptDelta(
    transcript.TranscriptDelta delta, {
    bool Function()? current,
  }) async {
    await waitForRelease(current);
    if (reject) throw StateError('controlled index failure');
    return super.applyTranscriptDelta(delta, current: current);
  }
}

// Controlled worker exit, with real pinned-WAV reads and durable scheduler
// commits. No speech model or actual capture/output device is opened here.
final class SavedExecution implements AudioRecognitionExecution {
  SavedExecution(this.media, this.lease, this.gate, {this.text}) {
    result = _run();
    result.ignore();
  }
  final RecordingMedia media;
  final AudioAsrLease lease;
  final Completer<void> gate;
  final String? text;
  final _closed = Completer<void>();
  bool cancelled = false;
  @override
  late final Future<List<AudioTranscriptResult>> result;
  @override
  Future<void> get closed => _closed.future;
  @override
  void cancel() {
    cancelled = true;
    if (!gate.isCompleted) gate.complete();
  }

  Future<List<AudioTranscriptResult>> _run() async {
    try {
      await gate.future;
      if (cancelled) return [];
      final job = lease.job;
      final chunks = media.audio.jobChunks(job.id);
      var marker = 0;
      for (final chunk in chunks) {
        final pcm = await media.readPcm(
          chunk,
          frameOffset: 0,
          frameCount: chunk.sampleCount,
        );
        marker = pcm.firstWhere((sample) => sample != 0, orElse: () => marker);
        if (marker != 0) break;
      }
      final span = media.audio
          .spans(job.sessionId)
          .singleWhere((s) => s.id == job.spanId);
      final times = recognitionPlaybackTimes(job, span, chunks);
      return [
        AudioTranscriptResult(
          text: text ?? 'marker_$marker',
          sampleStart: job.ownedStart,
          sampleEnd: job.ownedEnd,
          startMs: times.$1,
          endMs: times.$2,
        ),
      ];
    } finally {
      _closed.complete();
    }
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory root, profile;
  late String library;
  late DynamicLibrary fixture;
  late Store store;
  late Helper helper;
  late HeldIndexDomain domain;
  late Application app;
  late RecordingMedia media;
  late AudioSavedWork saved;
  late CapturePlatformFixture platform;
  late Map<String, String> environment;
  late int meeting;
  var profileNumber = 0;
  var ticks = 0, hold = false, notificationThrows = false;
  var expectedUnconfirmedStartup = false;
  String? speechText;
  final executions = <SavedExecution>[];

  int emit(int channel, Map<String, Object> event) {
    final value = jsonEncode(event).toNativeUtf8();
    try {
      return fixture.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>)
      >('fixture_emit')(channel, value);
    } finally {
      calloc.free(value);
    }
  }

  void speechEvent(String value) {
    final text = value.toNativeUtf8();
    try {
      fixture.lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('fixture_speech_event')(text);
    } finally {
      calloc.free(text);
    }
  }

  void holdSpeech(bool value) {
    hold = value;
    if (!value) {
      for (final execution in executions) {
        if (!execution.gate.isCompleted) execution.gate.complete();
      }
    }
  }

  CapturePlatformFixture capture(
    RecordingMedia owner,
  ) => CapturePlatformFixture(
    owner,
    onCreated: (route) {
      // Actual accepted silence proves acquisition before controls are used.
      route.audio(
        owner.audio
            .spans(route.reservations.first.sessionId)
            .singleWhere((s) => s.id == route.reservations.first.spanId)
            .captureStartUs,
      );
    },
  );
  void pcm([int marker = 411]) {
    final route = platform.routes.lastWhere(
      (r) => r.source == AudioSource.microphone && !r.finished,
    );
    final previous = route.through!;
    route.audio(
      previous,
      frames: 57600,
      voiced: true,
      voiceFrames: 9600,
      marker: marker,
    );
    platform.clock += 1200000;
    app.recording!.drain();
  }

  List<Map<String, Object?>> jobs() =>
      store.rows('SELECT * FROM audio_asr_jobs ORDER BY owned_start');
  Future<void> committed(int count) =>
      eventually(() => store.rows('SELECT * FROM transcript').length == count);
  void reject(String trigger, String target, String condition, String message) {
    store.db.execute(
      'CREATE TRIGGER $trigger BEFORE $target '
      "WHEN $condition BEGIN SELECT RAISE(ABORT, '$message'); END",
    );
  }

  Matcher storageError(String message) => isA<SqliteException>().having(
    (error) => error.message,
    'original SQLite failure',
    contains(message),
  );
  void physicallyStopped(Recording owner) {
    expect(platform.routes.every((r) => r.retired), isTrue);
    expect(owner.hasCaptureOwnership, isFalse);
    expect(owner.captureActive, isFalse);
    expect(owner.timer?.isActive ?? false, isFalse);
    expect(app.recording, isNull);
    expect(app.captureState['active'], false);
    expect(app.captureState['capture_active'], false);
  }

  void retainedAudio() {
    final chunks = store.rows(
      "SELECT * FROM audio_chunks WHERE state='published'",
    );
    expect(chunks, isNotEmpty);
    for (final row in chunks) {
      expect(
        media.audio.chunk(row['id'] as String)!.sampleCount,
        greaterThan(0),
      );
    }
  }

  setUpAll(() async {
    root = createTestTempDirectorySync('rec-storage-');
    library = '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    await buildCachedNativeFixture(
      source: 'test/fixtures/recording_native_stub.cpp',
      output: library,
    );
    fixture = DynamicLibrary.open(library);
  });
  setUp(() async {
    profile = Directory('${root.path}/profile-${profileNumber++}')
      ..createSync();
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment
      ..remove('FORESIGHT_INSTALL_ROOT')
      ..remove('FORESIGHT_RUNTIME_REVISION')
      ..['FORESIGHT_NATIVE'] = library
      ..['FORESIGHT_HELPER'] = '';
    store = Store('${profile.path}/app.db');
    helper = Helper(
      '${profile.path}/unused.sock',
      '${profile.path}/unused',
      manageProcess: false,
    );
    domain = HeldIndexDomain(store, helper);
    app = Application(domain);
    meeting = store.meeting('Controlled storage fault');
    final model = File('${profile.path}/speech-fixture')
      ..writeAsStringSync('ABI fixture only');
    await store.register('speech', model.path, '/usr/bin/true');
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    platform = capture(media);
    ticks = 0;
    hold = notificationThrows = false;
    expectedUnconfirmedStartup = false;
    speechText = null;
    executions.clear();
    saved = AudioSavedWork(
      media: media,
      bindings: NativeLibrary(fixture),
      changed: app.changed,
      nowMs: () => ticks += 1000000,
      committed: (result) {
        app.audioTranscriptCommitted(result);
        if (notificationThrows) {
          throw StateError('controlled postcommit observer');
        }
      },
      startRecognition: (lease) {
        final gate = Completer<void>();
        if (!hold) gate.complete();
        final execution = SavedExecution(media, lease, gate, text: speechText);
        executions.add(execution);
        return execution;
      },
    );
    saved.activate();
    app.configureDurableAudio(media, saved, capturePlatform: platform);
    speechEvent('');
    addTearDown(() async {
      holdSpeech(false);
      speechEvent('');
      if (!domain.release.isCompleted) domain.release.complete();
      if (!domain.cleanup.isCompleted) domain.cleanup.complete();
      for (final route in platform.routes) {
        if (route.finishHold?.isCompleted == false) {
          route.finishHold!.complete();
        }
      }
      if (platform.admission?.isCompleted == false) {
        platform.admission!.complete();
      }
      for (final row in store.rows(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'fault_%'",
      )) {
        store.db.execute('DROP TRIGGER ${row['name']}');
      }
      if (expectedUnconfirmedStartup) {
        await expectLater(app.close(), throwsA(anything));
        // These routes are controlled Dart fixtures, with no native callbacks.
        // Release the fixture-owned resources explicitly after proving refusal.
        for (final route in platform.routes) {
          route.rejectFinish = route.rejectRetire = false;
          await route.finish();
          route.poll();
          await route.retire();
        }
      } else {
        await app.close();
      }
      await saved.close();
      media.close();
      domain.close();
      await helper.close();
      store.close();
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
      profile.deleteSync(recursive: true);
    });
  });

  for (final fence in ['finish', 'retire']) {
    test(
      'failed startup retains a route whose native $fence is unconfirmed',
      () async {
        expectedUnconfirmedStartup = true;
        var admissions = 0;
        platform = CapturePlatformFixture(
          media,
          prepared: (_) {
            if (++admissions == 2) throw StateError('second device refused');
          },
          onCreated: (route) {
            route.rejectFinish = fence == 'finish';
            route.rejectRetire = fence == 'retire';
          },
        );
        app.configureDurableAudio(media, saved, capturePlatform: platform);
        await expectLater(app.startRecording(meeting), throwsA(anything));
        final owner = app.recording;
        expect(
          owner,
          isNotNull,
          reason: 'Unconfirmed native ownership survives start failure',
        );
        expect(owner!.hasCaptureOwnership, isTrue);
        expect(owner.lastError, isNotEmpty);
        expect(app.captureState['capture_active'], false);
        expect(app.captureState['active'], false);
        await expectLater(
          app.startRecording(meeting),
          throwsA(isA<RpcError>()),
        );
        final busy = isA<RpcError>().having(
          (e) => e.code,
          'code',
          RpcErrorCode.busy,
        );
        await expectLater(
          app.call('models.register', {
            'kind': 'speech',
            'path': store.sourceQueries.model('speech')!.path,
          }),
          throwsA(busy),
        );
        final epoch = store.workspaceEpoch;
        await expectLater(app.call('workspace.clear', {}), throwsA(busy));
        expect(store.workspaceEpoch, epoch);
        expect(platform.routes, hasLength(1));
        await expectLater(app.stopRecording(), throwsA(anything));
        expect(app.recording, same(owner));
      },
    );
  }

  test(
    'Stop during held durable start fences admission and permits a new session',
    () async {
      platform.admission = Completer<void>();
      final starting = app.startRecording(meeting);
      final cancelled = expectLater(
        starting,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await eventually(() => app.recording != null);
      final owner = app.recording!;
      var complete = false;
      final stopping = app.stopRecording().then((_) => complete = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(complete, isFalse);
      expect(platform.routes, isEmpty);
      platform.admission!.complete();
      await cancelled;
      await stopping;
      physicallyStopped(owner);
      await app.startRecording(meeting);
      expect(platform.routes, hasLength(2));
      await app.stopRecording();
    },
  );

  test(
    'initial state failure fences capture and preserves the SQLite error',
    () async {
      reject(
        'fault_initial',
        'UPDATE OF state ON meetings',
        "NEW.state IN ('starting','recording','transcribing','interrupted')",
        'initial storage fault',
      );
      await expectLater(
        app.startRecording(meeting),
        throwsA(storageError('initial storage fault')),
      );
      expect(app.recording, isNull);
      expect(platform.routes.every((r) => r.retired), isTrue);
      expect(app.recordingState, contains('Capture stopped'));
      expect(app.captureState['error'], app.recordingState);
      store.db.execute('DROP TRIGGER fault_initial');
      await app.startRecording(meeting);
      expect(app.captureState['error'], isNull);
      await app.stopRecording();
      expect(app.captureState['error'], isNull);
    },
  );

  test(
    'pre-stop failure and duplicate Stop join native fences without waiting for ASR',
    () async {
      await app.startRecording(meeting);
      final owner = app.recording!;
      holdSpeech(true);
      pcm();
      await eventually(() => executions.isNotEmpty);
      final route = platform.routes.first;
      route.finishHold = Completer<void>();
      reject(
        'fault_stop',
        'UPDATE OF state ON meetings',
        "NEW.state='transcribing'",
        'pre-stop storage fault',
      );
      final first = app.stopRecording();
      final failed = expectLater(
        first,
        throwsA(storageError('pre-stop storage fault')),
      );
      expect(app.stopRecording(), same(first));
      expect(app.recording, same(owner));
      expect(executions.single.gate.isCompleted, isFalse);
      route.finishHold!.complete();
      await failed.timeout(const Duration(seconds: 2));
      physicallyStopped(owner);
      retainedAudio();
      expect(jobs().single['state'], 'running');
      holdSpeech(false);
      await committed(1);
      expect(
        store.rows('SELECT text FROM transcript').single['text'],
        'marker_411',
      );
    },
  );

  test(
    'final state failure releases capture and retains committed transcript and audio',
    () async {
      await app.startRecording(meeting);
      final owner = app.recording!;
      pcm();
      await committed(1);
      reject(
        'fault_final',
        'UPDATE OF state ON meetings',
        "NEW.state='completed'",
        'final storage fault',
      );
      await expectLater(
        app.stopRecording(),
        throwsA(storageError('final storage fault')),
      );
      physicallyStopped(owner);
      retainedAudio();
      expect(
        store.rows('SELECT text FROM transcript').single['text'],
        'marker_411',
      );
      expect(app.recordingState, contains('metadata needs recovery'));
      expect(app.captureState['error'], app.recordingState);
    },
  );

  for (final partial in [false, true]) {
    test(
      '${partial ? 'transaction revision' : 'transcript insert'} failure retries durable job exactly once',
      () async {
        await app.startRecording(meeting);
        reject(
          'fault_transcript',
          partial ? 'UPDATE OF revision ON meetings' : 'INSERT ON transcript',
          '1',
          'transcript storage fault',
        );
        pcm();
        await eventually(() => jobs().any((r) => r['state'] == 'retry'));
        expect(store.rows('SELECT * FROM transcript'), isEmpty);
        expect(
          store.rows('SELECT revision FROM meetings').single['revision'],
          0,
        );
        retainedAudio();
        expect(app.captureState['capture_active'], isTrue);
        store.db.execute('DROP TRIGGER fault_transcript');
        saved.wake();
        await committed(1);
        expect(
          store.rows('SELECT text FROM transcript').single['text'],
          'marker_411',
        );
        expect(
          store.rows('SELECT revision FROM meetings').single['revision'],
          1,
        );
        expect(jobs().single['state'], 'completed');
        await app.stopRecording();
        expect(app.recordingState, contains('Audio saved'));
      },
    );
  }

  for (final stopFirst in [false, true]) {
    test(
      'ASR retry exhaustion retains audio ${stopFirst ? 'after Stop' : 'while capture continues'}',
      () async {
        await app.startRecording(meeting);
        final owner = app.recording!;
        reject(
          'fault_retry',
          'INSERT ON transcript',
          '1',
          'persistent storage fault',
        );
        pcm();
        await eventually(() => jobs().any((r) => r['state'] == 'retry'));
        if (stopFirst) await app.stopRecording();
        await eventually(() => jobs().any((r) => r['state'] == 'failed'));
        expect(jobs().single['error'], 'transcript_commit_failed');
        expect(jobs().single['attempts'], 5);
        expect(store.rows('SELECT * FROM transcript'), isEmpty);
        retainedAudio();
        if (stopFirst) {
          physicallyStopped(owner);
        } else {
          expect(app.recording, same(owner));
          expect(owner.captureActive, isTrue);
          await app.stopRecording();
        }
      },
    );
  }

  test(
    'queued durable transcripts recover in source order exactly once',
    () async {
      await app.startRecording(meeting);
      holdSpeech(true);
      for (var i = 0; i < 3; i++) {
        pcm(100 + i);
        await eventually(() => jobs().length == i + 1);
      }
      await app.stopRecording();
      retainedAudio();
      holdSpeech(false);
      await committed(3);
      expect(
        store
            .rows('SELECT text FROM transcript ORDER BY id')
            .map((r) => r['text']),
        ['marker_100', 'marker_101', 'marker_102'],
      );
      expect(store.rows('SELECT revision FROM meetings').single['revision'], 3);
    },
  );

  test(
    'more than64 pending ASR jobs remain on disk without stopping capture',
    () async {
      holdSpeech(true);
      await app.startRecording(meeting);
      final owner = app.recording!;
      for (var i = 0; i < 65; i++) {
        pcm(100 + i);
        await eventually(() => jobs().length == i + 1);
      }
      expect(jobs(), hasLength(65));
      expect(executions, hasLength(1));
      expect(app.recording, same(owner));
      expect(owner.captureActive, isTrue);
      retainedAudio();
      await app.stopRecording();
      physicallyStopped(owner);
      expect(jobs().where((r) => r['state'] == 'pending'), hasLength(64));
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
    },
  );

  for (final resume in [false, true]) {
    test(
      '${resume ? 'Resume' : 'Pause'} state-write failure fences admitted capture',
      () async {
        await app.startRecording(meeting);
        final owner = app.recording!;
        if (resume) {
          await app.pauseRecording();
          platform.clock += 1000000;
        }
        reject(
          'fault_control',
          'UPDATE OF state ON meetings',
          "NEW.state='${resume ? 'recording' : 'paused'}'",
          'control storage fault',
        );
        await expectLater(
          resume ? app.resumeRecording() : app.pauseRecording(),
          throwsA(storageError('control storage fault')),
        );
        await eventually(() => app.recording == null);
        physicallyStopped(owner);
        retainedAudio();
      },
    );
  }

  test(
    'oversized speech result is rejected while raw audio and capture survive',
    () async {
      speechText = 'x' * (1024 * 1024);
      await app.startRecording(meeting);
      final owner = app.recording!;
      pcm();
      await eventually(() => jobs().any((r) => r['state'] == 'failed'));
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
      retainedAudio();
      expect(app.recording, same(owner));
      expect(owner.captureActive, isTrue);
      await app.stopRecording();
    },
  );

  test(
    'postcommit observer failure never replays ASR over a user correction',
    () async {
      notificationThrows = true;
      domain.hold = true;
      await app.startRecording(meeting);
      pcm();
      await committed(1);
      await eventually(() => !saved.recognition.busy);
      store.db.execute("UPDATE transcript SET text='user correction'");
      for (var i = 0; i < 4; i++) {
        await saved.recognition.runOne();
        saved.wake();
      }
      expect(executions, hasLength(1));
      expect(jobs().single['state'], 'completed');
      expect(
        store.rows('SELECT text FROM transcript').single['text'],
        'user correction',
      );
      expect(store.rows('SELECT * FROM meeting_index_jobs'), isNotEmpty);
      await app.stopRecording();
    },
  );

  test(
    'next recording starts while prior indexing is held; close joins cancellation',
    () async {
      domain.hold = domain.holdCancellationCleanup = true;
      await app.startRecording(meeting);
      final owner = app.recording!;
      pcm();
      await committed(1);
      await app.stopRecording().timeout(const Duration(seconds: 2));
      await domain.entered.future;
      physicallyStopped(owner);
      final next = store.meeting('Next capture');
      await app.startRecording(next);
      expect(app.recordingMeeting, next);
      expect(app.recording!.captureActive, isTrue);
      await app.stopRecording();
      var closed = false;
      final closing = app.close().then((_) => closed = true);
      await domain.cancelled.future;
      expect(closed, isFalse);
      domain.cleanup.complete();
      await closing;
      expect(domain.indexed, isNot(contains('meeting-$meeting')));
      expect(
        store.rows('SELECT * FROM meeting_index_jobs WHERE meeting_id=?', [
          meeting,
        ]),
        hasLength(1),
      );
    },
  );

  test('late index failure cannot replace next recording status', () async {
    domain.hold = true;
    await app.startRecording(meeting);
    pcm();
    await committed(1);
    await app.stopRecording();
    await domain.entered.future;
    final next = store.meeting('New owner');
    await app.startRecording(next);
    final state = app.recordingState;
    domain.reject = true;
    domain.release.complete();
    await eventually(
      () => store
          .rows("SELECT state FROM sources WHERE id='meeting-$meeting'")
          .isNotEmpty,
    );
    await Future<void>.delayed(Duration.zero);
    expect(app.recordingState, state);
    expect(app.recordingMeeting, next);
    domain.reject = false;
    await app.stopRecording();
  });

  test(
    'late ASR commit for old meeting cannot replace current capture status',
    () async {
      holdSpeech(true);
      await app.startRecording(meeting);
      pcm();
      await eventually(() => executions.isNotEmpty);
      await app.stopRecording();
      final next = store.meeting('New ASR owner');
      await app.startRecording(next);
      final state = app.recordingState;
      domain.reject = true;
      holdSpeech(false);
      await committed(1);
      await eventually(() => !saved.recognition.busy);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(app.recordingState, state);
      expect(app.recordingMeeting, next);
      domain.reject = false;
      await app.stopRecording();
    },
  );

  for (final disconnect in [false, true]) {
    test(
      '${disconnect ? 'desktop disconnect' : 'desktop detach after hide'} fences durable capture despite state-write failure',
      () async {
        final label = disconnect ? 'disconnect' : 'hide';
        if (Platform.environment['FORESIGHT_TEST_CAPTURE_BOUNDARY_CHILD'] !=
            label) {
          await _freshBoundaryProcess(
            label,
            '${disconnect ? 'desktop disconnect' : 'desktop detach after hide'} fences durable capture despite state-write failure',
          );
          return;
        }
        File(
          '${Platform.environment['FORESIGHT_TEST_CAPTURE_BOUNDARY_EVIDENCE']!}/inputs.json',
        ).writeAsStringSync(
          jsonEncode({
            'pid': pid,
            for (final key in [
              'FORESIGHT_NATIVE_LIBRARY',
              'FORESIGHT_TEST_SQL_SUPPORT_LIBRARY',
              'FORESIGHT_SQLITE_LIBRARY',
            ])
              key: Platform.environment[key],
          }),
        );
        final data = '${root.path}/service-$label-d',
            runtime = '${root.path}/service-$label-r';
        late CapturePlatformFixture boundaryPlatform;
        final service = await ApplicationService.start(
          ProfilePaths(data, runtime),
          configuration: RuntimeConfiguration({
            ...runtimeConfiguration.environment,
            'FORESIGHT_NATIVE':
                Platform.environment['FORESIGHT_NATIVE_LIBRARY']!,
          }),
          desktopPeerVerifier: trustInProcessDesktop,
          capturePlatform: (owner) => boundaryPlatform = capture(owner),
        );
        final boundaryStore = service.domain.store;
        // The real runtime owns media and saved work. Register its cleanup
        // before admitting a client or touching the controller fixture.
        addTearDown(() async {
          boundaryStore.db.execute('DROP TRIGGER IF EXISTS fault_boundary');
          await service.close();
          Directory(data).deleteSync(recursive: true);
          if (Directory(runtime).existsSync()) {
            Directory(runtime).deleteSync(recursive: true);
          }
        });
        final desktop = await ServiceClient.connect(service.path);
        addTearDown(desktop.close);
        await desktop.call('security.attach_desktop', {
          'visible': true,
          'token': File('$data/.desktop-capability').readAsStringSync(),
        });
        await boundaryStore.register(
          'speech',
          store.sourceQueries.model('speech')!.path,
          '/usr/bin/true',
        );
        final id = boundaryStore.meeting('Boundary storage fault');
        await service.application.startRecording(id);
        final owner = service.application.recording!;
        boundaryStore.db.execute(
          "CREATE TRIGGER fault_boundary BEFORE UPDATE OF state ON meetings BEGIN SELECT RAISE(ABORT,'boundary storage fault'); END",
        );
        if (disconnect) {
          await desktop.close();
        } else {
          await desktop.call('security.desktop_visibility', {'visible': false});
          expect(service.application.recording, same(owner));
          expect(owner.captureActive, isTrue);
          expect(boundaryPlatform.routes.every((r) => !r.retired), isTrue);
          expect(service.access.hasVisibleHost, isFalse);
          await desktop.call('security.detach_desktop', {});
        }
        await eventually(() => service.application.recording == null);
        expect(boundaryPlatform.routes.every((r) => r.retired), isTrue);
        expect(owner.hasCaptureOwnership, isFalse);
        expect(owner.captureActive, isFalse);
      },
    );
  }

  test(
    'throwing speech interruption reporter retains the producer failure',
    () async {
      final original = StateError('controlled transcript observer failure');
      final owner = Recording(
        library,
        (_) {},
        (_, _, _, _) => throw original,
        interruption: (_) => throw StateError('secondary interruption failure'),
      );
      await owner.start(
        '/usr/bin/true',
        store.sourceQueries.model('speech')!.path,
      );
      addTearDown(() async {
        owner.dispose();
        await owner.closed;
      });
      final bytes = ByteData(40000);
      expect(
        emit(0, {
          'type': 'pcm',
          'sampleRate': 1000,
          'volume': .02,
          'data': base64Encode(bytes.buffer.asUint8List()),
        }),
        1,
      );
      owner.drain();
      await eventually(() => owner.captures.isEmpty);
      await expectLater(owner.stop(), throwsA(same(original)));
      expect(owner.speeches, isEmpty);
      expect(emit(1, {'type': 'state', 'state': 'late'}), 0);
    },
  );

  for (final duringDrain in [false, true]) {
    test(
      'throwing ${duringDrain ? 'interruption' : 'finalization state'} callback releases every native owner',
      () async {
        final original = StateError('controlled observer failure');
        var failState = false;
        final owner = Recording(
          library,
          (_) {
            if (failState) throw original;
          },
          (_, _, _, _) {},
          interruption: (_) => throw original,
        );
        await owner.start(
          '/usr/bin/true',
          store.sourceQueries.model('speech')!.path,
        );
        addTearDown(() async {
          owner.dispose();
          await owner.closed;
        });
        if (duringDrain) {
          expect(
            emit(0, {
              'type': 'gap',
              'reason': 'fixture_gap',
              'discarded_bytes': 1,
            }),
            1,
          );
          owner.drain();
          expect(owner.captures, isEmpty);
        } else {
          failState = true;
        }
        await expectLater(owner.stop(), throwsA(same(original)));
        expect(owner.captures, isEmpty);
        expect(owner.speeches, isEmpty);
        expect(owner.finishing, false);
        expect(emit(0, {'type': 'state', 'state': 'late'}), 0);
      },
    );
  }
}
