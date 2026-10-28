import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:foresight_core/src/application_services/audio_startup_recovery.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/audio_segmentation.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late Store store;
  late RecordingMedia media;
  late AudioSession session;
  late AudioSpan span;
  var current = true;

  AudioSpan prepare(AudioSession owner) {
    final value = media.audio.startSpan(
      owner.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    AudioSegmentationOwner(
      store: media.audio,
      ownerGeneration: media.ownerGeneration,
      readPcm: (_, {required frameOffset, required frameCount}) =>
          throw StateError('Startup cannot read unverified audio'),
    ).prepare(
      span: value,
      source: AudioSource.microphone,
      modelRevision: 'frozen',
      initialSample: 0,
    );
    return value;
  }

  setUp(() {
    root = createTestTempDirectorySync('audio-recovery-pages-');
    store = Store('${root.path}/application.db');
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    media.admitNewCapture();
    session = media.audio.createSession(
      meetingId: store.meeting('Interrupted'),
      startedWallMs: 0,
    );
    span = prepare(session);
    current = true;
    addTearDown(() {
      media.close();
      store.close();
    });
  });

  AudioStartupRecovery recovery(RecoverAudioBatch recover) =>
      AudioStartupRecovery(
        media: media,
        bindings: NativeLibrary(DynamicLibrary.process()),
        current: () => current,
        nowMs: () => 900000000000,
        recover: recover,
      );

  List<AudioChunkPublication> reserve(int start, int count) =>
      media.preallocate(
        span: span,
        source: AudioSource.microphone,
        firstSequence: start,
        count: count,
      );

  test(
    'startup publication seal waits actual reconciliation and never starts capture',
    () async {
      reserve(0, 1);
      final admitted = Completer<void>(), fence = Completer<List<AudioChunk>>();
      final owner = recovery((_) {
        admitted.complete();
        return fence.future;
      });
      final running = owner.run();
      expect(owner.run(), same(running));
      await admitted.future;
      expect(media.audio.span(span.id)!.captureEndUs, isNull);
      expect(
        media.audio
            .segmentation(session.id, AudioSource.microphone, span.id)!
            .publicationSealed,
        isFalse,
      );
      fence.complete([]);
      final report = await running;
      expect(report.sessions, 1);
      expect(report.problemCount, 0);
      expect(media.audio.span(span.id)!.captureEndUs, 0);
      expect(
        media.audio.session(session.id)!.captureState,
        AudioCaptureState.interrupted,
      );
      expect(
        media.audio
            .segmentation(session.id, AudioSource.microphone, span.id)!
            .publicationSealed,
        isTrue,
      );
    },
  );

  test(
    'crash duration uses saved acquisition extent instead of restart wall clock',
    () async {
      final authority = reserve(0, 1).single;
      media.audio.publishPreallocatedChunk(
        authority.id,
        publicationToken: authority.publicationToken,
        sampleStart: 0,
        sampleCount: 4800,
        sampleRate: 48000,
        channels: 1,
        captureStartUs: 1000,
        captureEndUs: 101000,
        byteLength: 9796,
        sha256: 'a' * 64,
      );
      await recovery(
        (_) async =>
            throw StateError('Published metadata is not a pending orphan'),
      ).run();
      expect(media.audio.span(span.id)!.captureEndUs, 101000);
      expect(media.audio.span(span.id)!.playbackEndUs, 101000);
    },
  );

  test('pending authorities are paged beyond a long meeting batch', () async {
    reserve(0, 64);
    reserve(64, 64);
    reserve(128, 13);
    final seen = <String>{};
    var largest = 0, calls = 0;
    final report = await recovery((values) async {
      calls++;
      if (values.length > largest) largest = values.length;
      for (final value in values) {
        expect(seen.add(value.id), isTrue);
      }
      return [];
    }).run();
    expect(report.sessions, 1);
    expect(seen, hasLength(141));
    expect(largest, 64);
    expect(calls, 3);
  });

  test('session pages do not truncate older meeting history', () async {
    for (var index = 1; index < 141; index++) {
      prepare(
        media.audio.createSession(
          meetingId: session.meetingId,
          startedWallMs: index,
        ),
      );
    }
    final report = await recovery((_) async => []).run();
    expect(report.sessions, 141);
    expect(() => media.audio.recoverySessions(limit: 257), throwsArgumentError);
  });

  test(
    'bad candidate cannot hide other authorities and never authorizes final flush',
    () async {
      final values = reserve(0, 3);
      final bad = values.first.id, singles = <String>{};
      final report = await recovery((batch) async {
        if (batch.length > 1) throw StateError('Batch has corrupt candidate');
        singles.add(batch.single.id);
        if (batch.single.id == bad) throw StateError('Corrupt header');
        return [];
      }).run();
      expect(singles, values.map((value) => value.id).toSet());
      expect(report.problemCount, 1);
      expect(report.problems.single.chunkId, bad);
      expect(
        media.audio.session(session.id)!.terminalError,
        'recording_recovery_failed',
      );
      expect(
        media.audio
            .segmentation(session.id, AudioSource.microphone, span.id)!
            .publicationSealed,
        isFalse,
      );
    },
  );

  test('cancelled reconciliation cannot close or seal a stale span', () async {
    reserve(0, 1);
    await expectLater(
      recovery((_) async {
        current = false;
        return [];
      }).run(),
      throwsA(anything),
    );
    expect(media.audio.span(span.id)!.captureEndUs, isNull);
    expect(
      media.audio
          .segmentation(session.id, AudioSource.microphone, span.id)!
          .publicationSealed,
      isFalse,
    );
  });

  test(
    'generation rotation during recovery refuses all later metadata mutation',
    () async {
      reserve(0, 1);
      await expectLater(
        recovery((_) async {
          media.audio.rotateStorageGeneration(metadataOnly: true);
          return [];
        }).run(),
        throwsStateError,
      );
      expect(
        media.audio
            .segmentation(session.id, AudioSource.microphone, span.id)!
            .publicationSealed,
        isFalse,
      );
    },
  );

  test(
    'metadata-only restore cannot adopt newer audio using restored rows',
    () async {
      reserve(0, 1);
      media.close();
      store.close();
      final database = File('${root.path}/application.db');
      database.copySync('${root.path}/restored.db');
      File('${root.path}/restored.db').renameSync(database.path);
      store = Store(database.path);
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      expect(media.audio.mediaAdmitted, isFalse);
      final report = await recovery(
        (_) async => throw StateError('No adoption allowed'),
      ).run();
      expect(report.sessions, 0);
      expect(report.recoveredChunks, 0);
      expect(
        media.audio.session(session.id)!.terminalError,
        'restored_without_audio',
      );
    },
  );
}
