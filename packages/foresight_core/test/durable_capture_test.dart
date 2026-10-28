import 'dart:async';
import 'dart:io' as io;

import 'package:foresight_core/src/application_services/recording_audio_work.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/durable_capture.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/recording.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';
import 'fixtures/durable_capture_routes.dart';

final class Work implements RecordingAudioWorkPort {
  final prepared = <AudioSpan>[], sealed = <AudioSpan>[];
  final starts = <Map<AudioSource, int>>[];
  final revisions = <String>[];
  final chunks = <AudioChunk>[], stopped = <AudioSession>[];
  bool rejectPrepare = false, rejectHint = false;
  @override
  void prepareSpan(
    AudioSpan span, {
    required String modelRevision,
    required Map<AudioSource, int> sourceStarts,
  }) {
    if (rejectPrepare) throw StateError('segmentation metadata unavailable');
    prepared.add(span);
    starts.add(sourceStarts);
    revisions.add(modelRevision);
  }

  @override
  void published(AudioChunk chunk) {
    chunks.add(chunk);
    if (rejectHint) throw StateError('worker wake failed');
  }

  @override
  void spanSealed(AudioSpan span) => sealed.add(span);
  @override
  void captureStopped(AudioSession session) => stopped.add(session);
}

Future<void> settle(DurableCaptureController owner) async {
  for (var i = 0; i < 30; i++) {
    owner.poll();
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Store store;
  late RecordingMedia media;
  late Work work;
  late CapturePlatformFixture platform;
  late DurableCaptureController owner;
  late List<String> states;
  var rejectChanged = false;
  setUp(() {
    final root = createTestTempDirectorySync('durable-capture-');
    store = Store('${root.path}/app.db');
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    work = Work();
    platform = CapturePlatformFixture(
      media,
      prepared: (ordinal) => expect(work.prepared.last.ordinal, ordinal),
    );
    states = [];
    rejectChanged = false;
    owner = DurableCaptureController(
      media: media,
      meetingId: store.meeting('Durable meeting'),
      modelRevision: 'frozen-speech-digest',
      work: work,
      platform: platform,
      now: () => DateTime.fromMicrosecondsSinceEpoch(platform.clock),
      createTimer: (_, callback) => Timer(const Duration(days: 1), callback),
      state: states.add,
      changed: () {
        if (rejectChanged) throw StateError('controlled observer failure');
      },
    );
    addTearDown(() async {
      for (final route in platform.routes) {
        if (route.finishHold?.isCompleted == false) {
          route.finishHold!.complete();
        }
        if (route.reserveHold?.isCompleted == false) {
          route.reserveHold!.complete();
        }
      }
      owner.dispose();
      try {
        await owner.closed;
      } catch (_) {}
      media.close();
      store.close();
    });
  });

  test(
    'preallocates both sources and frozen segmentation before acquisition',
    () async {
      await owner.start();
      expect(platform.routes, hasLength(2));
      expect(owner.captureActive, isFalse);
      expect(owner.starting, isTrue);
      expect(
        media.audio.session(owner.sessionId!)!.captureState,
        AudioCaptureState.starting,
      );
      expect(work.revisions, ['frozen-speech-digest']);
      expect(work.starts.single, {
        AudioSource.microphone: 0,
        AudioSource.playback: 0,
      });
      platform.routes.first.audio(0);
      owner.poll();
      expect(owner.captureActive, isTrue);
      expect(
        media.audio.session(owner.sessionId!)!.captureState,
        AudioCaptureState.recording,
      );
      await owner.stop();
      expect(platform.routes.every((r) => r.retired), isTrue);
    },
  );
  test(
    'more than four retained silent chunks survive Stop without ASR drain',
    () async {
      await owner.start(playback: false);
      work.rejectHint = true;
      final route = platform.routes.single;
      for (var i = 0; i < 6; i++) {
        route.audio(i * 100000);
      }
      owner.poll();
      await owner.stop();
      expect(work.chunks, hasLength(6));
      expect(owner.sampleCounts.first, 28800);
      expect(
        media.audio.session(owner.sessionId!)!.captureState,
        AudioCaptureState.stopped,
      );
      expect(work.sealed, hasLength(1));
      expect(work.stopped, hasLength(1));
      expect(owner.lastError, isEmpty);
      expect(owner.backgroundError, contains('worker wake failed'));
      expect(states.last, contains('Audio saved'));
      expect(states.any((s) => s.contains('No speech')), isFalse);
    },
  );
  test(
    'finish acknowledgement precedes final notices, commit, empty poll and retirement',
    () async {
      await owner.start(playback: false);
      final route = platform.routes.single;
      route.audio(0, finalOnly: true);
      route.finishHold = Completer<void>();
      var done = false;
      final stop = owner.stop().then((_) => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      expect(route.retired, isFalse);
      expect(work.sealed, isEmpty);
      route.finishHold!.complete();
      await stop;
      expect(work.chunks, hasLength(1));
      expect(
        route.log.indexOf('finish-ack'),
        lessThan(route.log.indexOf('poll-after-finish:1')),
      );
      expect(
        route.log,
        containsAllInOrder([
          'finish-ack',
          'poll-after-finish:1',
          'poll-after-finish:0',
          'retire',
        ]),
      );
    },
  );
  test(
    'shared spans compact only pause and retain source gaps and sample positions',
    () async {
      await owner.start();
      platform.routes[0].audio(0);
      platform.routes[1].audio(10000);
      owner.poll();
      await owner.pause();
      expect(owner.paused, isTrue);
      expect(owner.elapsedMs, 110);
      platform.clock += 2000000;
      await owner.resume();
      expect(work.starts.last, {
        AudioSource.microphone: 4800,
        AudioSource.playback: 4800,
      });
      final next = platform.routes.skip(2).toList();
      next[0].audio(2000000);
      next[1].audio(2250000, gap: true);
      owner.poll();
      await owner.stop();
      final spans = media.audio.spans(owner.sessionId!);
      expect(spans, hasLength(2));
      expect(spans[1].playbackStartUs, 110000);
      expect(spans[1].captureStartUs, 2000000);
      expect(owner.elapsedMs, 460);
      expect(
        work.chunks.where((c) => c.gapBefore).single.source,
        AudioSource.playback,
      );
      expect(
        work.chunks.map((c) => c.sequence).toSet().length,
        2,
        reason: 'newspan cannot reuse reserved sequence authority',
      );
    },
  );
  test(
    'held reservation fsync cannot freeze metadata, meters or fresh inactivity',
    () async {
      await owner.start(playback: false);
      final route = platform.routes.single;
      route.reserveHold = Completer<void>();
      for (var i = 0; i < 8; i++) {
        route.audio(i * 100000);
      }
      owner.poll();
      platform.clock += 1000000;
      route.audio(1000000, voiced: true);
      owner.poll();
      expect(owner.currentVolumes.first, .1);
      expect(owner.elapsedMs, 1100);
      platform.clock += 5000000;
      owner.poll();
      expect(owner.inactiveFor.inSeconds, 4);
      owner.poll();
      expect(
        owner.inactiveFor.inSeconds,
        4,
        reason: 'repeated snapshot cannot renew activity',
      );
      route.reserveHold!.complete();
      await owner.stop();
    },
  );
  test(
    'publication failure fences every route and never asserts a sealed source',
    () async {
      await owner.start();
      platform.routes[0].audio(0, corrupt: true);
      platform.routes[1].audio(0);
      owner.poll();
      await expectLater(owner.stop(), throwsFormatException);
      expect(platform.routes.every((r) => r.retired), isTrue);
      expect(work.sealed, isEmpty);
      expect(
        media.audio.session(owner.sessionId!)!.captureState,
        AudioCaptureState.interrupted,
      );
      final warning = states.last;
      owner.poll();
      expect(states.last, warning);
      expect(owner.captureActive, isFalse);
    },
  );
  test(
    'recording status transaction failure cannot discard publication or retain capture',
    () async {
      await owner.start();
      store.db.execute(
        "CREATE TRIGGER fault_recording BEFORE UPDATE ON recording_sessions WHEN NEW.capture_state='recording' BEGIN SELECT RAISE(ABORT,'controlled capture status failure'); END",
      );
      platform.routes[0].audio(0);
      platform.routes[1].audio(10000);
      owner.poll();
      await expectLater(owner.stop(), throwsA(isA<SqliteException>()));
      expect(platform.routes.every((r) => r.retired), isTrue);
      expect(work.chunks, hasLength(2));
      expect(owner.lastError, contains('Saved audio is retained'));
    },
  );
  test(
    'unconfirmed retirement suppresses publication seal despite closed duration span',
    () async {
      await owner.start(playback: false);
      platform.routes.single.audio(0);
      platform.routes.single.rejectRetire = true;
      owner.poll();
      await expectLater(owner.stop(), throwsStateError);
      expect(work.sealed, isEmpty);
      expect(media.audio.spans(owner.sessionId!).single.captureEndUs, 100000);
      expect(owner.hasCaptureOwnership, isTrue);
    },
  );
  test(
    'Stop during admission prevents later physical capture creation',
    () async {
      platform.admission = Completer<void>();
      final start = owner.start();
      final startError = expectLater(start, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final stop = owner.stop();
      platform.admission!.complete();
      await startError;
      await stop;
      expect(platform.routes, isEmpty);
      expect(owner.captureActive, isFalse);
    },
  );
  test(
    'observer failure still commits drained notices and fences every source',
    () async {
      await owner.start();
      platform.routes[0].audio(0);
      platform.routes[1].audio(0);
      rejectChanged = true;
      owner.poll();
      await expectLater(owner.stop(), throwsStateError);
      expect(platform.routes.every((route) => route.retired), isTrue);
      expect(work.chunks, hasLength(2));
    },
  );
  test(
    'durable Recording facade keeps ASR detached and reflects pause and meters',
    () async {
      final recording = Recording.durable(
        io.Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6',
        states.add,
        (_, _, _, _) {},
        media: media,
        work: work,
        meetingId: store.meeting('Facade'),
        modelRevision: 'frozen-model',
        now: () => DateTime.fromMicrosecondsSinceEpoch(platform.clock),
        createTimer: (_, callback) => Timer(const Duration(days: 1), callback),
        platform: platform,
      );
      addTearDown(() async {
        recording.dispose();
        await recording.closed;
      });
      await recording.start(
        '/missing/asr-runtime',
        '/missing/model',
        playback: false,
      );
      final route = platform.routes.single;
      route.audio(0, voiced: true);
      recording.drain();
      expect(recording.sampleCounts, [4800, 0]);
      expect(recording.currentVolumes.first, .1);
      expect(recording.speeches, isEmpty);
      expect(recording.captureActive, isTrue);
      await recording.pause();
      expect(recording.paused, isTrue);
      expect(recording.captureActive, isFalse);
      platform.clock += 2000000;
      await recording.resume();
      platform.routes.last.audio(2000000);
      recording.drain();
      await recording.stop();
      expect(recording.lastError, isEmpty);
      expect(work.chunks, hasLength(2));
      expect(recording.recordedElapsedMs, 200);
    },
  );
  test(
    'missing durable native exports fail visibly without legacy capture',
    () async {
      final recording = Recording.durable(
        io.Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6',
        states.add,
        (_, _, _, _) {},
        media: media,
        work: work,
        meetingId: store.meeting('Missing ABI'),
        modelRevision: 'frozen-model',
        now: DateTime.now,
        createTimer: Timer.new,
      );
      await expectLater(
        recording.start('/usr/bin/true', '/missing/model'),
        throwsStateError,
      );
      recording.dispose();
      await expectLater(recording.closed, throwsStateError);
      expect(recording.captures, isEmpty);
      expect(recording.speeches, isEmpty);
      expect(recording.lastError, contains('audio storage or capture failed'));
    },
  );

  test('segmentation metadata failure admits no device', () async {
    work.rejectPrepare = true;
    await expectLater(owner.start(), throwsStateError);
    await expectLater(owner.stop(), throwsStateError);
    expect(platform.routes, isEmpty);
    expect(work.sealed, isEmpty);
  });
}
