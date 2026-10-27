import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../audio_models.dart';
import '../native_lifetime.dart';
import '../persistence/audio_store.dart';
import '../rpc_error.dart';
import '../runtime_execution_policy.dart';
import 'audio_recognition_scheduler.dart';

/// The model coordinator verifies this frozen revision and holds replacement
/// admission until release. A model lease has no GC-driven release/finalizer.
final class AudioSpeechModelLease {
  AudioSpeechModelLease({
    required this.revision,
    required this.runtime,
    required this.path,
    required Future<void> Function() release,
  }) : _release = release;
  final String revision, runtime, path;
  final Future<void> Function() _release;
  Future<void>? _released;
  Future<void> release() => _released ??= Future<void>.sync(_release);
}

typedef ReadRecordingPcm =
    Future<Int16List> Function(
      AudioChunk chunk, {
      required int frameOffset,
      required int frameCount,
    });
typedef AcquireSpeechModel =
    Future<AudioSpeechModelLease> Function(
      String revision,
      bool Function() current,
    );

/// Recognition of already captured, lossless audio. It never acquires devices.
/// Current native ASR emits a single whole-job transcript, so overlap is refused
/// until a timestamped owned-range cropping capability is actually available.
final class NativeAudioRecognition implements AudioRecognitionExecution {
  NativeAudioRecognition({
    required this.bindings,
    required this.store,
    required this.lease,
    required this.readPcm,
    required this.acquireModel,
    this.queueTimeout = const Duration(seconds: 60),
    this.executionTimeout = const Duration(seconds: 60),
  }) {
    _result.future.ignore();
    _closed.future.ignore();
    _run().ignore();
  }

  final NativeLibrary bindings;
  final AudioStore store;
  final AudioAsrLease lease;
  final ReadRecordingPcm readPcm;
  final AcquireSpeechModel acquireModel;
  final Duration queueTimeout, executionTimeout;
  final _result = Completer<List<AudioTranscriptResult>>();
  final _closed = Completer<void>();
  bool _cancelled = false;
  int _handle = 0;
  @override
  Future<List<AudioTranscriptResult>> get result => _result.future;
  @override
  Future<void> get closed => _closed.future;

  @override
  void cancel() {
    _cancelled = true;
    if (_handle != 0) {
      final cancel = bindings.library
          .lookupFunction<Int32 Function(Uint64), int Function(int)>(
            'fs_owned_speech_cancel',
          );
      if (cancel(_handle) != 0) {
        throw StateError('Native speech cancellation was refused');
      }
    }
  }

  void _checkCurrent() {
    if (_cancelled) {
      throw RpcError(RpcErrorCode.cancelled, 'Saved transcription cancelled');
    }
  }

  Future<void> _run() async {
    // Return the owned execution before admitting a model, file or native task.
    await Future<void>.value();
    AudioSpeechModelLease? model;
    Object? failure;
    StackTrace? failureStack;
    List<AudioTranscriptResult>? results;
    var retired = false;
    try {
      _checkCurrent();
      final job = lease.job;
      if (job.sampleStart != job.ownedStart ||
          job.sampleEnd != job.ownedEnd ||
          job.sampleEnd <= job.sampleStart ||
          job.sampleEnd - job.sampleStart > 48000 * 20) {
        throw const AudioRecognitionBlocked('unsupported_recognition_range');
      }
      model = await acquireModel(job.modelRevision, () => !_cancelled);
      _checkCurrent();
      if (model.revision != job.modelRevision) {
        throw const AudioRecognitionBlocked('frozen_model_unavailable');
      }
      final chunks = store.jobChunks(job.id);
      final spans = store.spans(job.sessionId);
      final span = spans.where((span) => span.id == job.spanId).firstOrNull;
      if (span == null || chunks.isEmpty || chunks.length > 256) {
        throw const AudioRecognitionBlocked('audio_unavailable');
      }
      final times = recognitionPlaybackTimes(job, span, chunks);
      await bindings.prepareAdmission();
      _checkCurrent();
      bindings.lifetime.ensureAdmission();
      final runtime = requireInstalledRuntime(model.runtime).toNativeUtf8();
      final path = model.path.toNativeUtf8();
      try {
        final create = bindings.library
            .lookupFunction<
              Uint64 Function(Pointer<Utf8>, Pointer<Utf8>),
              int Function(Pointer<Utf8>, Pointer<Utf8>)
            >('fs_owned_speech_create');
        _handle = create(runtime, path);
        if (_handle == 0) {
          throw const AudioRecognitionBlocked('speech_runtime_unavailable');
        }
      } finally {
        calloc.free(runtime);
        calloc.free(path);
      }
      final push = bindings.library
          .lookupFunction<
            Int32 Function(Uint64, Pointer<Int16>, Size, Int32),
            int Function(int, Pointer<Int16>, int, int)
          >('fs_owned_speech_push');
      for (final chunk in chunks) {
        final start = job.sampleStart > chunk.sampleStart
            ? job.sampleStart
            : chunk.sampleStart;
        final end = job.sampleEnd < chunk.sampleEnd
            ? job.sampleEnd
            : chunk.sampleEnd;
        if (end <= start) continue;
        final pcm = await readPcm(
          chunk,
          frameOffset: start - chunk.sampleStart,
          frameCount: end - start,
        );
        _checkCurrent();
        if (pcm.length != end - start) {
          throw const AudioRecognitionBlocked('audio_unavailable');
        }
        final samples = calloc<Int16>(pcm.length);
        try {
          samples.asTypedList(pcm.length).setAll(0, pcm);
          if (push(_handle, samples, pcm.length, 48000) != 0) {
            throw StateError('Native speech input was refused');
          }
        } finally {
          calloc.free(samples);
        }
      }
      _checkCurrent();
      final request = job.id.toNativeUtf8();
      try {
        final finish = bindings.library
            .lookupFunction<
              Int32 Function(Uint64, Pointer<Utf8>),
              int Function(int, Pointer<Utf8>)
            >('fs_owned_speech_finish');
        if (finish(_handle, request) != 0) {
          throw StateError('Native speech request was refused');
        }
      } finally {
        calloc.free(request);
      }
      final text = await _recognize(job.id);
      if (await bindings.lifetime.request('fs_speech_join_async', _handle) !=
          1) {
        throw StateError('Native speech join failed');
      }
      _checkCurrent();
      results = text.isEmpty
          ? const []
          : [
              AudioTranscriptResult(
                text: text,
                sampleStart: job.ownedStart,
                sampleEnd: job.ownedEnd,
                startMs: times.$1,
                endMs: times.$2,
              ),
            ];
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      try {
        if (_handle != 0) {
          await bindings.lifetime.retire('fs_speech_retire', _handle);
          _handle = 0;
        }
        retired = true;
        await model?.release();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
        // Keep a model lease on uncertain native ownership. Its coordinator
        // refuses replacement until native process ownership is recovered.
      }
      if (failure == null) {
        _result.complete(results!);
      } else {
        _result.completeError(failure, failureStack);
      }
      if (retired) {
        _closed.complete();
      } else {
        _closed.completeError(failure!, failureStack);
      }
    }
  }

  Future<String> _recognize(String requestId) async {
    final poll = bindings.library
        .lookupFunction<
          Pointer<Utf8> Function(Uint64, Int32),
          Pointer<Utf8> Function(int, int)
        >('fs_owned_event_poll');
    final free = bindings.library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('fs_string_free');
    var running = false, previousSequence = -1;
    final elapsed = Stopwatch()..start();
    String? text;
    while (true) {
      _checkCurrent();
      final limit = running ? executionTimeout : queueTimeout;
      if (elapsed.elapsed >= limit) {
        throw TimeoutException(
          running ? 'Speech execution timed out' : 'Speech admission timed out',
          limit,
        );
      }
      final value = poll(_handle, 0);
      if (value == nullptr) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        continue;
      }
      late final Map<String, dynamic> event;
      try {
        final decoded = value.toDartString();
        if (decoded.length > 131072) {
          throw const FormatException('Oversized speech event');
        }
        event = jsonDecode(decoded) as Map<String, dynamic>;
      } finally {
        free(value);
      }
      final sequence = event['sequence'];
      if (event['request_id'] != requestId ||
          sequence is! int ||
          sequence <= previousSequence) {
        throw const FormatException('Mismatched speech result ownership');
      }
      previousSequence = sequence;
      if (event['type'] == 'state' &&
          event['phase'] == 'speech_running' &&
          !running) {
        running = true;
        elapsed.reset();
      } else if (event['type'] == 'transcript') {
        if (text != null ||
            event['text'] is! String ||
            (event['text'] as String).length > 65536) {
          throw const FormatException('Unsupported speech result shape');
        }
        text = (event['text'] as String).trim();
      } else if (event['type'] == 'done') {
        if (event['status'] != 'completed') {
          throw StateError('Speech recognition failed');
        }
        return text == '[BLANK_AUDIO]' ? '' : text ?? '';
      }
    }
  }
}

/// Whole-job transcript timing follows acquisition anchors and the shared span,
/// preserving route offsets and pauses. No word timestamps are inferred.
(int, int) recognitionPlaybackTimes(
  AudioAsrJob job,
  AudioSpan span,
  List<AudioChunk> chunks,
) {
  var cursor = job.sampleStart;
  int? startUs, endUs;
  for (final chunk in chunks) {
    if (chunk.sampleEnd <= job.sampleStart ||
        chunk.sampleStart >= job.sampleEnd) {
      continue;
    }
    if (chunk.sessionId != job.sessionId ||
        chunk.spanId != job.spanId ||
        chunk.source != job.source ||
        chunk.sampleRate != 48000 ||
        chunk.channels != 1 ||
        chunk.state != AudioChunkState.published ||
        chunk.sampleStart > cursor ||
        (cursor > job.sampleStart && chunk.sampleStart != cursor) ||
        (cursor > job.sampleStart && chunk.gapBefore)) {
      throw const AudioRecognitionBlocked('discontinuous_audio_range');
    }
    final start = cursor > chunk.sampleStart ? cursor : chunk.sampleStart;
    final end = job.sampleEnd < chunk.sampleEnd
        ? job.sampleEnd
        : chunk.sampleEnd;
    final anchor =
        span.playbackStartUs + chunk.captureStartUs - span.captureStartUs;
    startUs ??= anchor + (start - chunk.sampleStart) * 1000000 ~/ 48000;
    endUs = anchor + (end - chunk.sampleStart) * 1000000 ~/ 48000;
    cursor = end;
  }
  if (cursor != job.sampleEnd ||
      startUs == null ||
      endUs == null ||
      startUs < 0 ||
      endUs < startUs) {
    throw const AudioRecognitionBlocked('audio_unavailable');
  }
  return (startUs ~/ 1000, endUs ~/ 1000);
}
