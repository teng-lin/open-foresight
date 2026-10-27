import 'dart:async';
import 'dart:ffi';

import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/application_services/audio_recognition_scheduler.dart';
import 'package:foresight_core/src/application_services/audio_saved_work.dart';
import 'package:foresight_core/src/application_services/native_audio_recognition.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/store.dart';

import 'durable_capture_routes.dart';

// Application consumer fixture: real retained WAV/SQL/segmentation and owned
// commits; controlled acquisition and recognizer, without hardware or a model.
final class DurableSpeechFixture {
  DurableSpeechFixture(
    this.app,
    Store store,
    DynamicLibrary bindings, {
    required String text,
  }) : media = RecordingMedia.open(
         store,
         ownerGeneration: AudioStore.newIdentity(),
       ) {
    platform = CapturePlatformFixture(
      media,
      onCreated: (route) {
        route.audio(
          media.audio
              .spans(route.reservations.first.sessionId)
              .singleWhere((s) => s.id == route.reservations.first.spanId)
              .captureStartUs,
        );
      },
    );
    var now = 0;
    saved = AudioSavedWork(
      media: media,
      bindings: NativeLibrary(bindings),
      changed: app.changed,
      committed: app.audioTranscriptCommitted,
      nowMs: () => now += 1000000,
      startRecognition: (lease) => _SavedText(media, lease, text),
    );
    saved.activate();
    app.configureDurableAudio(media, saved, capturePlatform: platform);
  }
  final Application app;
  final RecordingMedia media;
  late final AudioSavedWork saved;
  late final CapturePlatformFixture platform;
  void voice(AudioSource source) {
    final route = platform.routes.lastWhere(
      (r) => r.source == source && !r.finished,
    );
    route.audio(
      route.through!,
      frames: 57600,
      voiced: true,
      voiceFrames: 9600,
      marker: 211,
    );
    platform.clock += 1200000;
    app.recording!.drain();
  }

  Future<void> close() async {
    await app.close();
    await saved.close();
    media.close();
  }
}

final class _SavedText implements AudioRecognitionExecution {
  _SavedText(RecordingMedia media, AudioAsrLease lease, String text) {
    result = () async {
      final chunks = media.audio.jobChunks(lease.job.id);
      var voiced = false;
      for (final chunk in chunks) {
        final pcm = await media.readPcm(
          chunk,
          frameOffset: 0,
          frameCount: chunk.sampleCount,
        );
        voiced |= pcm.any((sample) => sample != 0);
      }
      if (_cancelled) return <AudioTranscriptResult>[];
      if (!voiced) throw StateError('Fixture recognized no acquired voice');
      final span = media.audio
          .spans(lease.job.sessionId)
          .singleWhere((s) => s.id == lease.job.spanId);
      final times = recognitionPlaybackTimes(lease.job, span, chunks);
      return [
        AudioTranscriptResult(
          text: text,
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
