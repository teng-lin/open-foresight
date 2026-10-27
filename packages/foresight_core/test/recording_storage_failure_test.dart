import 'sql_support_test_bootstrap.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/generated/transcript_index.pb.dart'
    as transcript;
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/desktop_identity.dart';
import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

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

void main() {
  bootstrapSqlSupportFixture();
  late Directory root, profile;
  late String library;
  late DynamicLibrary fixture;
  late Store store;
  late Helper helper;
  late HeldIndexDomain domain;
  late Application app;
  late Map<String, String> environment;
  late int meeting;
  var holdRetryTimers = false;

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

  void holdSpeech(bool value) =>
      fixture.lookupFunction<Void Function(Int32), void Function(int)>(
        'fixture_hold_speech',
      )(value ? 1 : 0);
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

  void pcm([int marker = 411]) {
    final bytes = ByteData(40000);
    for (var i = 0; i < 20000; i++) {
      bytes.setInt16(i * 2, marker, Endian.little);
    }
    expect(
      emit(0, {
        'type': 'pcm',
        'sampleRate': 1000,
        'volume': .02,
        'data': base64Encode(bytes.buffer.asUint8List()),
      }),
      1,
    );
    app.recording!.drain();
  }

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
    expect(owner.captures, isEmpty);
    expect(owner.speeches, isEmpty);
    expect(owner.timer?.isActive, isFalse);
    for (final channel in [0, 1]) {
      expect(emit(channel, {'type': 'state', 'state': 'late'}), 0);
    }
    expect(app.recording, isNull);
    expect(app.captureState['active'], false);
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
    profile = Directory('${root.path}/profile')..createSync();
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
    holdRetryTimers = false;
    domain = HeldIndexDomain(
      store,
      helper,
      createTimer: (duration, callback) {
        // Isolate count admission from elapsed retry budgets in the cap fixture.
        return Timer(
          holdRetryTimers && duration == const Duration(seconds: 1)
              ? const Duration(days: 1)
              : duration,
          callback,
        );
      },
    );
    app = Application(domain);
    meeting = store.meeting('Controlled storage fault');
    final model = File('${profile.path}/speech-fixture')
      ..writeAsStringSync('ABI fixture only');
    await store.register('speech', model.path, '/usr/bin/true');
    holdSpeech(false);
    speechEvent('');
    addTearDown(() async {
      holdSpeech(false);
      speechEvent('');
      if (!domain.release.isCompleted) domain.release.complete();
      for (final row in store.rows(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'fault_%'",
      )) {
        store.db.execute('DROP TRIGGER ${row['name']}');
      }
      await app.close();
      domain.close();
      await helper.close();
      store.close();
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
      profile.deleteSync(recursive: true);
    });
  });

  test(
    'Stop during a held recording start joins cleanup and prevents late device admission',
    () async {
      final holdRetirement = fixture
          .lookupFunction<Void Function(Int32), void Function(int)>(
            'fixture_hold_retirement',
          );
      final pendingRetirements = fixture
          .lookupFunction<Int32 Function(), int Function()>(
            'fixture_pending_retirements',
          );
      final captureCreations = fixture
          .lookupFunction<Int32 Function(), int Function()>(
            'fixture_capture_creations',
          );
      final before = captureCreations();
      holdRetirement(1);
      Future<void>? stopped;
      try {
        final starting = app.startRecording(meeting);
        final cancelled = expectLater(
          starting,
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.cancelled,
            ),
          ),
        );
        await eventually(() => pendingRetirements() == 1);
        final owner = app.recording!;
        expect(owner.starting, isTrue);
        var complete = false;
        stopped = app.stopRecording().then((_) => complete = true);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(
          complete,
          isFalse,
          reason: 'The native startup owner has not actually retired',
        );
        expect(captureCreations(), before);
        holdRetirement(0);
        await cancelled;
        await stopped;
        expect(owner.captures, isEmpty);
        expect(owner.speeches, isEmpty);
        expect(
          owner.timer,
          isNull,
          reason: 'The cancelled start never admitted a capture timer',
        );
        expect(app.recording, isNull);
        expect(app.captureState['active'], isFalse);
        for (final channel in [0, 1]) {
          expect(emit(channel, {'type': 'state', 'state': 'late'}), 0);
        }
        expect(
          captureCreations(),
          before,
          reason: 'The obsolete start must not open devices after Stop',
        );
        await app.startRecording(meeting);
        expect(captureCreations(), before + 2);
        await app.stopRecording();
      } finally {
        holdRetirement(0);
        await stopped;
      }
    },
  );

  test(
    'initial state failure stops physical capture and preserves original error',
    () async {
      reject(
        'fault_initial',
        'UPDATE OF state ON meetings',
        "NEW.state IN ('recording','transcribing','interrupted')",
        'initial storage fault',
      );
      await expectLater(
        app.startRecording(meeting),
        throwsA(storageError('initial storage fault')),
      );
      expect(app.recording, isNull);
      expect(app.recordingMeeting, isNull);
      for (final channel in [0, 1]) {
        expect(emit(channel, {'type': 'state', 'state': 'late'}), 0);
      }
      expect(app.recordingState, contains('Capture stopped'));
      store.db.execute('DROP TRIGGER fault_initial');
      await app.startRecording(meeting);
      await app.stopRecording();
    },
  );

  test(
    'pre-stop failure still drains speech and duplicate Stop joins cleanup',
    () async {
      await app.startRecording(meeting);
      final owner = app.recording!;
      holdSpeech(true);
      pcm();
      await eventually(() => owner.speeches.isNotEmpty);
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
      expect(owner.captures, isEmpty);
      await eventually(() => emit(0, {'type': 'state', 'state': 'late'}) == 0);
      expect(
        app.recording,
        same(owner),
        reason: 'Speech still owns finalization',
      );
      holdSpeech(false);
      await failed;
      physicallyStopped(owner);
      expect(
        store.rows('SELECT text FROM transcript').single['text'],
        'marker_411',
      );
      expect(
        store.rows('SELECT state FROM meetings').single['state'],
        'interrupted',
      );
    },
  );

  test(
    'final state failure releases capture and retains committed transcript',
    () async {
      await app.startRecording(meeting);
      final owner = app.recording!;
      pcm();
      await eventually(() => store.rows('SELECT * FROM transcript').isNotEmpty);
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
      expect(
        store.rows('SELECT text FROM transcript').single['text'],
        'marker_411',
      );
      expect(app.recordingState, contains('could not be saved'));
    },
  );

  for (final partial in [false, true]) {
    test(
      '${partial ? 'partial transcript write' : 'transcript insert'} retries once without duplicate committed text',
      () async {
        await app.startRecording(meeting);
        reject(
          'fault_transcript',
          partial ? 'UPDATE OF revision ON meetings' : 'INSERT ON transcript',
          '1',
          'transcript storage fault',
        );
        pcm();
        await eventually(
          () => app.captureState['transcript_persistence'] == 'retrying',
        );
        expect(
          store.rows('SELECT * FROM transcript'),
          isEmpty,
          reason: 'A revision failure must roll back the preceding insert',
        );
        store.db.execute('DROP TRIGGER fault_transcript');
        await app.stopRecording();
        expect(
          store.rows('SELECT text FROM transcript').single['text'],
          'marker_411',
        );
        expect(
          store.rows('SELECT revision FROM meetings').single['revision'],
          1,
        );
        expect(app.captureState['unsaved_segments'], 0);
        expect(app.captureState['transcript_persistence'], 'saved');
        expect(app.recordingState, 'Transcript saved');
      },
    );
  }

  test(
    'retry exhaustion stops acquisition and reports unsaved text explicitly',
    () async {
      await app.startRecording(meeting);
      final owner = app.recording!;
      reject(
        'fault_transcript',
        'INSERT ON transcript',
        '1',
        'persistent storage fault',
      );
      pcm();
      await eventually(
        () => app.captureState['transcript_persistence'] == 'retrying',
      );
      final stopped = app.stopRecording();
      await expectLater(
        stopped,
        throwsA(storageError('persistent storage fault')),
      );
      physicallyStopped(owner);
      expect(app.captureState['transcript_persistence'], 'failed');
      expect(app.captureState['unsaved_segments'], 1);
      expect(app.recordingState, contains('Some speech was not saved'));
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
    },
  );

  test(
    'automatic retry exhaustion ends live capture without a Stop request',
    () async {
      await app.startRecording(meeting);
      final owner = app.recording!;
      reject(
        'fault_auto',
        'INSERT ON transcript',
        '1',
        'automatic retry fault',
      );
      pcm();
      await eventually(
        () => app.recording == null,
        timeout: const Duration(seconds: 8),
      );
      physicallyStopped(owner);
      expect(app.captureState['unsaved_segments'], 1);
      expect(app.recordingState, contains('Some speech was not saved'));
    },
  );

  test('queued transcripts recover in order exactly once', () async {
    await app.startRecording(meeting);
    reject('fault_ordered', 'INSERT ON transcript', '1', 'ordered retry fault');
    for (var segment = 0; segment < 3; segment++) {
      pcm(100 + segment);
      await eventually(
        () => app.captureState['unsaved_segments'] == segment + 1,
      );
    }
    store.db.execute('DROP TRIGGER fault_ordered');
    await app.stopRecording();
    expect(
      store
          .rows('SELECT text FROM transcript ORDER BY id')
          .map((row) => row['text']),
      ['marker_100', 'marker_101', 'marker_102'],
    );
    expect(store.rows('SELECT revision FROM meetings').single['revision'], 3);
  });

  test(
    'segment-count budget stops capture instead of growing pending text',
    () async {
      holdRetryTimers = true;
      await app.startRecording(meeting);
      final owner = app.recording!;
      reject('fault_count', 'INSERT ON transcript', '1', 'count budget fault');
      for (var segment = 0; segment < 64; segment++) {
        pcm(segment);
        await eventually(
          () => app.captureState['unsaved_segments'] == segment + 1,
        );
      }
      expect(app.captureState['unsaved_segments'], 64);
      pcm(65);
      await eventually(() => app.recording == null);
      physicallyStopped(owner);
      expect(app.captureState['unsaved_segments'], 65);
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
    },
  );

  for (final resume in [false, true]) {
    test(
      '${resume ? 'Resume' : 'Pause'} state-write failure shuts down admitted capture',
      () async {
        await app.startRecording(meeting);
        final owner = app.recording!;
        if (resume) await app.pauseRecording();
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
        expect(owner.captures, isEmpty);
        await eventually(() => app.recording == null);
        physicallyStopped(owner);
      },
    );
  }

  test(
    'one oversized text segment exhausts the byte budget and stops capture',
    () async {
      await app.startRecording(meeting);
      final owner = app.recording!;
      speechEvent(
        jsonEncode({'type': 'transcript', 'text': 'x' * (1024 * 1024)}),
      );
      pcm();
      await eventually(() => app.recording == null);
      physicallyStopped(owner);
      expect(app.captureState['unsaved_segments'], 1);
      expect(app.captureState['transcript_persistence'], 'failed');
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
    },
  );

  test(
    'next recording starts while previous indexing is held; close still joins it',
    () async {
      domain.hold = true;
      domain.holdCancellationCleanup = true;
      await app.startRecording(meeting);
      final owner = app.recording!;
      pcm();
      await eventually(() => store.rows('SELECT * FROM transcript').isNotEmpty);
      await app.stopRecording().timeout(const Duration(seconds: 2));
      await domain.entered.future;
      physicallyStopped(owner);
      final next = store.meeting('Next capture');
      await app.startRecording(next);
      expect(app.recordingMeeting, next);
      expect(emit(0, {'type': 'state', 'state': 'capturing'}), 1);
      await app.stopRecording();
      var closed = false;
      final closing = app.close().then((_) => closed = true);
      await domain.cancelled.future;
      expect(closed, false);
      domain.cleanup.complete();
      await closing;
      expect(domain.indexed, isNot(contains('meeting-$meeting')));
      expect(
        store.rows('SELECT * FROM meeting_index_jobs WHERE meeting_id=?', [
          meeting,
        ]),
        hasLength(1),
        reason: 'Cancelled owned work survives close as durable intent',
      );
    },
  );

  test(
    'late failed indexing cannot replace the next recording status',
    () async {
      domain.hold = true;
      await app.startRecording(meeting);
      pcm();
      await eventually(() => store.rows('SELECT * FROM transcript').isNotEmpty);
      await app.stopRecording();
      await domain.entered.future;
      final next = store.meeting('New capture owner');
      await app.startRecording(next);
      final currentState = app.recordingState;
      domain.reject = true;
      domain.release.complete();
      await eventually(
        () => store
            .rows("SELECT state FROM sources WHERE id='meeting-$meeting'")
            .isNotEmpty,
      );
      await Future<void>.delayed(Duration.zero);
      expect(app.recordingState, currentState);
      expect(app.recordingMeeting, next);
      domain.reject = false;
      await app.stopRecording();
    },
  );

  for (final disconnect in [false, true]) {
    test(
      '${disconnect ? 'desktop disconnect' : 'hide'} physically stops capture despite state-write failure',
      () async {
        final data = '${root.path}/service-d';
        final runtime = '${root.path}/service-r';
        // Start the storage-only service, then attach the controlled capture
        // ABI. This fixture deliberately has no native configuration API.
        runtimeConfiguration.environment.remove('FORESIGHT_NATIVE');
        final service = await ApplicationService.start(
          ProfilePaths(data, runtime),
          desktopPeerVerifier: trustInProcessDesktop,
        );
        runtimeConfiguration.environment['FORESIGHT_NATIVE'] = library;
        final desktop = await ServiceClient.connect(service.path);
        addTearDown(() async {
          service.domain.store.db.execute(
            'DROP TRIGGER IF EXISTS fault_boundary',
          );
          await desktop.close();
          await service.close();
          Directory(data).deleteSync(recursive: true);
          if (Directory(runtime).existsSync()) {
            Directory(runtime).deleteSync(recursive: true);
          }
        });
        await desktop.call('security.attach_desktop', {
          'visible': true,
          'token': File('$data/.desktop-capability').readAsStringSync(),
        });
        final boundaryStore = service.domain.store;
        final model = store.sourceQueries.model('speech')!;
        await boundaryStore.register('speech', model.path, '/usr/bin/true');
        final id = boundaryStore.meeting('Boundary storage fault');
        await service.application.startRecording(id);
        final owner = service.application.recording!;
        boundaryStore.db.execute(
          "CREATE TRIGGER fault_boundary BEFORE UPDATE OF state ON meetings BEGIN SELECT RAISE(ABORT, 'boundary storage fault'); END",
        );
        if (disconnect) {
          await desktop.close();
        } else {
          await desktop.call('security.desktop_visibility', {'visible': false});
        }
        await eventually(() => service.application.recording == null);
        expect(owner.captures, isEmpty);
        expect(owner.speeches, isEmpty);
        expect(emit(0, {'type': 'state', 'state': 'late'}), 0);
        expect(emit(1, {'type': 'state', 'state': 'late'}), 0);
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
