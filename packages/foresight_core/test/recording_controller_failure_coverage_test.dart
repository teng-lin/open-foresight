import 'sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:async';

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
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'fixtures/durable_capture_routes.dart';

// Real saved-WAV reads and durable ASR commits, with controlled speech output.
// This does not exercise a model, native capture device or native speech worker.
final class _Recognition implements AudioRecognitionExecution {
  _Recognition(RecordingMedia media, AudioAsrLease lease) {
    result = () async {
      final chunks = media.audio.jobChunks(lease.job.id);
      var marker = 0;
      for (final chunk in chunks) {
        final samples = await media.readPcm(
          chunk,
          frameOffset: 0,
          frameCount: chunk.sampleCount,
        );
        marker = samples.firstWhere((s) => s != 0, orElse: () => marker);
        if (marker != 0) break;
      }
      if (_cancelled) return <AudioTranscriptResult>[];
      final span = media.audio
          .spans(lease.job.sessionId)
          .singleWhere((s) => s.id == lease.job.spanId);
      final times = recognitionPlaybackTimes(lease.job, span, chunks);
      return [
        AudioTranscriptResult(
          text: 'marker_$marker',
          sampleStart: lease.job.ownedStart,
          sampleEnd: lease.job.ownedEnd,
          startMs: times.$1,
          endMs: times.$2,
        ),
      ];
    }().whenComplete(() => _closed.complete());
    result.ignore();
  }
  bool _cancelled = false;
  final _closed = Completer<void>();
  @override
  late final Future<List<AudioTranscriptResult>> result;
  @override
  Future<void> get closed => _closed.future;
  @override
  void cancel() => _cancelled = true;
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory root, profile;
  late String library;
  late DynamicLibrary fixture;
  late Store store;
  late Helper helper;
  late AdapterDomain domain;
  late Application app;
  late RecordingMedia media;
  late AudioSavedWork saved;
  late CapturePlatformFixture platform;
  var refusedChannel = -1, admissions = 0, nowMs = 0;
  late Map<String, String> environment;
  late int meeting;

  void failChannel(int value) {
    refusedChannel = value;
    admissions = 0;
  }

  int emit(Map<String, Object> value) {
    final pointer = jsonEncode(value).toNativeUtf8();
    try {
      return fixture.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>)
      >('fixture_emit')(0, pointer);
    } finally {
      calloc.free(pointer);
    }
  }

  CaptureRouteFixture getMicrophone() => platform.routes.lastWhere(
    (r) => r.source == AudioSource.microphone && !r.finished,
  );
  void pcm(int marker, int count, {int? voicedFrames, bool gap = false}) {
    final route = getMicrophone();
    route.audio(
      route.through!,
      frames: count,
      voiced: marker != 0,
      voiceFrames: voicedFrames,
      marker: marker,
      gap: gap,
    );
    platform.clock += count * 1000000 ~/ 48000;
    app.recording!.drain();
  }

  setUpAll(() async {
    root = createTestTempDirectorySync('recording-controller-errors-');
    library = '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    await buildCachedNativeFixture(
      source: 'test/fixtures/recording_native_stub.cpp',
      output: library,
    );
    fixture = DynamicLibrary.open(library);
    addTearDown(() => root.deleteSync(recursive: true));
  });
  setUp(() async {
    profile = Directory('${root.path}/profile')..createSync();
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment
      ..remove('FORESIGHT_INSTALL_ROOT')
      ..remove('FORESIGHT_RUNTIME_REVISION')
      ..['FORESIGHT_NATIVE'] = library;
    store = Store('${profile.path}/app.db');
    helper = Helper(
      '${profile.path}/unused.sock',
      '${profile.path}/unused',
      manageProcess: false,
    );
    domain = AdapterDomain(store, helper);
    app = Application(domain);
    meeting = store.meeting('Controlled capture');
    failChannel(-1);
    nowMs = 0;
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    platform = CapturePlatformFixture(
      media,
      prepared: (_) {
        if (admissions++ == refusedChannel) {
          throw StateError('fixture route refused');
        }
      },
      onCreated: (route) {
        route.audio(
          media.audio
              .spans(route.reservations.first.sessionId)
              .singleWhere((s) => s.id == route.reservations.first.spanId)
              .captureStartUs,
        );
      },
    );
    saved = AudioSavedWork(
      media: media,
      bindings: NativeLibrary(fixture),
      changed: app.changed,
      committed: app.audioTranscriptCommitted,
      nowMs: () => nowMs += 1000000,
      startRecognition: (lease) => _Recognition(media, lease),
    );
    saved.activate();
    app.configureDurableAudio(media, saved, capturePlatform: platform);
    addTearDown(() async {
      failChannel(-1);
      await app.close();
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

  Future<void> speechModel() async {
    final model = File('${profile.path}/speech-fixture')
      ..writeAsStringSync('ABI fixture only');
    await store.register('speech', model.path, '/usr/bin/true');
  }

  String meetingState() =>
      store.rows('SELECT state FROM meetings WHERE id=?', [
            meeting,
          ]).single['state']
          as String;

  test(
    'capture startup refusal releases the first channel and leaves meeting retryable',
    () async {
      await expectLater(
        app.startRecording(meeting),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.unavailable,
          ),
        ),
      );
      await speechModel();
      failChannel(1);
      await expectLater(
        app.startRecording(meeting),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      expect(platform.routes, hasLength(1));
      expect(platform.routes.single.retired, isTrue);
      expect(emit({'type': 'state', 'state': 'must not be delivered'}), 0);
      expect(app.recording, isNull);
      expect(app.captureState['active'], isFalse);
      await expectLater(
        app.stopRecording(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'capture refusal',
            contains('fixture route refused'),
          ),
        ),
      );
      expect(meetingState(), 'interrupted');
      failChannel(-1);
      await app.startRecording(meeting);
      expect(app.captureState['active'], isTrue);
      await app.stopRecording();
      expect(app.recording, isNull);
    },
  );

  test(
    'acquisition gaps retain shared-clock metadata alongside committed speech',
    () async {
      await speechModel();
      await app.startRecording(meeting);
      pcm(211, 9600);
      await eventually(
        () =>
            media.audio.db
                .select("SELECT 1 FROM audio_chunks WHERE state='published'")
                .length >=
            3,
      );
      expect(app.provisionalTranscript, isEmpty);
      pcm(0, 48000);
      await eventually(
        () => store.rows('SELECT * FROM transcript WHERE final=1').isNotEmpty,
      );
      expect(app.provisionalTranscript.values, everyElement(isEmpty));
      final route = getMicrophone(), before = route.through!;
      platform.clock += 500000;
      route.audio(before + 500000, frames: 4800, gap: true);
      app.recording!.drain();
      await eventually(
        () => media.audio.db
            .select('SELECT 1 FROM audio_chunks WHERE gap_before=1')
            .isNotEmpty,
      );
      final gap = media.audio.db
          .select(
            'SELECT id,session_id,capture_start_us,sample_start FROM audio_chunks WHERE gap_before=1',
          )
          .single;
      expect(gap['capture_start_us'], before + 500000);
      expect(gap['sample_start'], 62400);
      expect(store.rows('SELECT * FROM transcript WHERE final=0'), isEmpty);
      expect(meetingState(), 'recording');
      await app.stopRecording(
        reason: 'Recording stopped because the desktop was hidden.',
      );
      expect(
        app.recordingState,
        contains('Recording stopped because the desktop was hidden.'),
      );
      expect(meetingState(), 'completed');
      final geometry = media.audio.playbackTimeline.chunk(
        gap['session_id'] as String,
        gap['id'] as String,
        authority: media.audio.playbackTimelineAuthority,
      );
      expect(geometry!.startFrame, 62400 + 24000);
      expect(geometry.frameCount, 4800);
      expect(
        store.rows('SELECT * FROM transcript WHERE final=1').single['text'],
        'marker_211',
      );
      expect(app.captureState['active'], isFalse);
      expect(app.provisionalTranscript, isEmpty);
      await app.indexMeeting(meeting);
      expect(domain.indexed, isNotEmpty);
    },
  );

  test('inactivity finalizes capture and releases its owned devices', () async {
    await speechModel();
    store.setPreference('inactivity', '0.001');
    await app.startRecording(meeting);
    platform.clock += 1000000;
    await eventually(
      () => app.recording == null,
      timeout: const Duration(seconds: 8),
    );
    expect(emit({'type': 'state', 'state': 'late'}), 0);
    expect(meetingState(), 'completed');
    final retained = media.audio.db.select(
      "SELECT * FROM audio_chunks WHERE state='published'",
    );
    expect(retained, isNotEmpty);
    for (final row in retained) {
      final chunk = media.audio.chunk(row['id'] as String)!;
      final silence = await media.readPcm(
        chunk,
        frameOffset: 0,
        frameCount: chunk.sampleCount,
      );
      expect(silence, hasLength(chunk.sampleCount));
      expect(silence, everyElement(0));
    }
    expect(platform.routes.every((r) => r.retired), isTrue);
    expect(store.rows('SELECT * FROM transcript'), isEmpty);
    expect(app.captureState['active'], isFalse);
    expect(
      app.recordingState,
      contains('Recording stopped after 0.001 minutes without audio.'),
    );
  });

  test(
    'capture failure retains committed text and publishes interrupted state',
    () async {
      await speechModel();
      await app.startRecording(meeting);
      pcm(319, 57600, voicedFrames: 9600);
      await eventually(
        () => store.rows('SELECT * FROM transcript WHERE final=1').isNotEmpty,
      );
      getMicrophone().error = 'fixture route disappeared';
      app.recording!.drain();
      // Capture failure is independent of already committed background ASR.
      await expectLater(
        app.stopRecording(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'original capture failure',
            contains('fixture route disappeared'),
          ),
        ),
      );
      expect(app.recordingState, contains('Capture interrupted'));
      expect(app.recordingState, contains('Saved audio is retained'));
      expect(meetingState(), 'interrupted');
      expect(
        store.rows('SELECT * FROM transcript WHERE final=1').single['text'],
        'marker_319',
      );
      expect(app.recording, isNull);
      expect(platform.routes.every((r) => r.retired), isTrue);
      expect(app.recordingMeeting, isNull);
      expect(emit({'type': 'state', 'state': 'late'}), 0);
    },
  );
}
