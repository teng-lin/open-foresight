import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'audio_models.dart';
import 'native_lifetime.dart';
import 'rpc_error.dart';

const _maximumInteger = 0x1fffffffffffff;
final _uuid = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
);

String _identity(Object? value) {
  if (value is! String || !_uuid.hasMatch(value)) {
    throw const FormatException('Invalid recording identity');
  }
  return value;
}

int _integer(Object? value, {int maximum = _maximumInteger}) {
  if (value is! int || value < 0 || value > maximum) {
    throw const FormatException('Invalid recording integer');
  }
  return value;
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid recording object');
  }
  return value;
}

bool _boolean(Object? value) {
  if (value is! bool) {
    throw const FormatException('Invalid recording flag');
  }
  return value;
}

double _volume(Object? value) {
  if (value is! num || !value.isFinite || value < 0 || value > 1) {
    throw const FormatException('Invalid recording level');
  }
  return value.toDouble();
}

enum RecordingCapturePhase {
  preparing,
  starting,
  capturing,
  sealing,
  sealed,
  failed,
}

enum RecordingClockQuality {
  unavailable,
  hardwareHostTime,
  pipeDrainEstimate,
  linuxPts,
  pipewireHeaderPts,
  pipewireGraphTime,
}

/// A publication notice is evidence to validate against SQLite authority and
/// actual file bytes. It never grants filesystem access by itself.
final class RecordingChunkNotice {
  RecordingChunkNotice.fromJson(Map<String, dynamic> value)
    : chunkId = _identity(value['chunk_id']),
      sessionId = _identity(value['session_id']),
      generation = _identity(value['generation']),
      source = AudioSource.values[_integer(value['source'], maximum: 1)],
      sequence = _integer(value['sequence']),
      span = _integer(value['span']),
      sourceSample = _integer(value['source_sample']),
      frames = _integer(value['frames'], maximum: 240000),
      captureStartUs = _integer(value['capture_start_us']),
      byteLength = _integer(value['bytes'], maximum: 480196),
      interrupted = _boolean(value['interrupted']),
      gapBefore = _boolean(value['gap_before']),
      contentsSynced = _boolean(value['contents_synced']),
      directorySynced = _boolean(value['directory_synced']) {
    if (frames == 0 ||
        value['sample_rate'] != 48000 ||
        value['channels'] != 1 ||
        byteLength != 196 + frames * 2 ||
        value['relative_path'] != '$chunkId.wav') {
      throw const FormatException('Invalid recording publication format');
    }
  }

  final String chunkId, sessionId, generation;
  final AudioSource source;
  final int sequence, span, sourceSample, frames, captureStartUs, byteLength;
  final bool interrupted, gapBefore, contentsSynced, directorySynced;
  int get captureEndUs => captureStartUs + frames * 1000000 ~/ 48000;
}

final class RecordingCaptureSnapshot {
  RecordingCaptureSnapshot.fromJson(Map<String, dynamic> value)
    : sessionId = _identity(value['session_id']),
      generation = _identity(value['generation']),
      source = AudioSource.values[_integer(value['source'], maximum: 1)],
      span = _integer(value['span']),
      ready = _boolean(value['ready']),
      captureActive = _boolean(value['capture_active']),
      sourceSample = _integer(value['source_sample']),
      queuedFrames = _integer(value['queued_frames'], maximum: 307200),
      readyChunks = _integer(value['ready_chunks'], maximum: 64),
      reservedChunks = _integer(value['reserved_chunks'], maximum: 64),
      outstandingChunks = _integer(value['outstanding_chunks'], maximum: 64) {
    if (value['version'] != 1) {
      throw const FormatException('Unsupported recording capture version');
    }
    phase = switch (value['state']) {
      'preparing' => RecordingCapturePhase.preparing,
      'starting' => RecordingCapturePhase.starting,
      'capturing' => RecordingCapturePhase.capturing,
      'sealing' => RecordingCapturePhase.sealing,
      'sealed' => RecordingCapturePhase.sealed,
      'failed' => RecordingCapturePhase.failed,
      _ => throw const FormatException('Invalid recording capture state'),
    };
    clockQuality = switch (value['clock_quality']) {
      'unavailable' => RecordingClockQuality.unavailable,
      'hardware_host_time' => RecordingClockQuality.hardwareHostTime,
      'pipe_drain_estimate' => RecordingClockQuality.pipeDrainEstimate,
      'linux_pts' => RecordingClockQuality.linuxPts,
      'pipewire_header_pts' => RecordingClockQuality.pipewireHeaderPts,
      'pipewire_graph_time' => RecordingClockQuality.pipewireGraphTime,
      _ => throw const FormatException('Invalid recording capture clock'),
    };
    final uncertainty = value['uncertainty_us'];
    uncertaintyUs = uncertainty == null ? null : _integer(uncertainty);
    currentVolume = _volume(value['current_volume']);
    peakVolume = _volume(value['peak_volume']);
    final acquired = value['acquired_through_us'];
    acquiredThroughUs = acquired == null ? null : _integer(acquired);
    final voice = value['last_voice_capture_us'];
    lastVoiceCaptureUs = voice == null ? null : _integer(voice);
    final warning = value['error'];
    if (warning != null && (warning is! String || warning.length > 4096)) {
      throw const FormatException('Invalid recording capture error');
    }
    error = warning as String?;
    if (captureActive &&
        (!ready || phase != RecordingCapturePhase.capturing || error != null)) {
      throw const FormatException('Inconsistent recording capture state');
    }
    final publications = value['chunks'];
    if (publications is! List || publications.length > 64) {
      throw const FormatException('Unbounded recording publication batch');
    }
    final ids = <String>{};
    chunks = List.unmodifiable(
      publications.map((value) {
        final chunk = RecordingChunkNotice.fromJson(_object(value));
        if (chunk.sessionId != sessionId ||
            chunk.generation != generation ||
            chunk.source != source ||
            chunk.span != span ||
            !ids.add(chunk.chunkId)) {
          throw const FormatException('Mismatched recording publication owner');
        }
        return chunk;
      }),
    );
  }

  final String sessionId, generation;
  final AudioSource source;
  final int span,
      sourceSample,
      queuedFrames,
      readyChunks,
      reservedChunks,
      outstandingChunks;
  final bool ready, captureActive;
  late final RecordingCapturePhase phase;
  late final RecordingClockQuality clockQuality;
  late final int? uncertaintyUs;
  late final int? lastVoiceCaptureUs, acquiredThroughUs;
  late final double currentVolume, peakVolume;
  late final String? error;
  late final List<RecordingChunkNotice> chunks;
}

/// One owned capture route. Reservations must already be durable in SQLite.
/// Physical acquisition and fsync run on native owned lanes. This owner outlives
/// a finish acknowledgement until its last publication notices are drained.
final class RecordingCapture {
  RecordingCapture._(
    this._bindings,
    this._handle,
    this.sessionId,
    this.generation,
    this.source,
    this.span,
    this._spanId,
  );

  static Future<RecordingCapture> start({
    required NativeLibrary bindings,
    required String target,
    required AudioSource source,
    required String directory,
    required String sessionId,
    required String generation,
    required int span,
    required int originUs,
    required int sourceSample,
    required List<AudioChunkPublication> reservations,
    required bool Function() mayStart,
    bool echoCancellation = false,
  }) async {
    if (target.contains('\u0000') ||
        target.length > 4096 ||
        !directory.startsWith('/') ||
        directory.contains('\u0000')) {
      throw ArgumentError('Invalid recording capture target or directory');
    }
    final options = jsonEncode({
      'directory': directory,
      'session_id': _identity(sessionId),
      'generation': _identity(generation),
      'span': _integer(span),
      'origin_us': _integer(originUs),
      'source_sample': _integer(sourceSample),
      'chunk_ids': _reservations(reservations, sessionId, generation, source),
    });
    final lib = bindings.library;
    for (final symbol in const [
      'fs_owned_recording_capture_start',
      'fs_owned_capture_recording_poll',
      'fs_owned_capture_reserve_async',
      'fs_recording_monotonic_us',
    ]) {
      if (!lib.providesSymbol(symbol)) {
        throw StateError('Durable recording capture is unavailable');
      }
    }
    await bindings.prepareAdmission();
    if (!mayStart()) {
      throw RpcError(RpcErrorCode.cancelled, 'Recording start cancelled');
    }
    bindings.lifetime.ensureAdmission();
    final start = lib
        .lookupFunction<
          Uint64 Function(Pointer<Utf8>, Int32, Int32, Pointer<Utf8>),
          int Function(Pointer<Utf8>, int, int, Pointer<Utf8>)
        >('fs_owned_recording_capture_start');
    final nativeTarget = target.toNativeUtf8();
    final nativeOptions = options.toNativeUtf8();
    try {
      final handle = start(
        nativeTarget,
        source.index,
        echoCancellation ? 1 : 0,
        nativeOptions,
      );
      if (handle == 0) throw StateError('Recording capture was not admitted');
      return RecordingCapture._(
        bindings,
        handle,
        sessionId,
        generation,
        source,
        span,
        reservations.first.spanId,
      );
    } finally {
      calloc.free(nativeTarget);
      calloc.free(nativeOptions);
    }
  }

  static List<Map<String, Object>> _reservations(
    List<AudioChunkPublication> values,
    String sessionId,
    String generation,
    AudioSource source,
  ) {
    if (values.isEmpty || values.length > 64) {
      throw ArgumentError('Recording reservations must contain 1..64 chunks');
    }
    final ids = <String>{}, sequences = <int>{}, spans = <String>{};
    return values.map((value) {
      if (value.sessionId != sessionId ||
          value.storageGeneration != generation ||
          value.source != source ||
          value.relativePath !=
              'recordings/$generation/$sessionId/${value.id}.wav' ||
          !ids.add(value.id) ||
          !sequences.add(value.sequence)) {
        throw ArgumentError('Mismatched recording reservation');
      }
      spans.add(value.spanId);
      if (spans.length != 1) throw ArgumentError('Mixed recording spans');
      return <String, Object>{
        'id': _identity(value.id),
        'sequence': _integer(value.sequence),
      };
    }).toList();
  }

  static int monotonicUs(NativeLibrary bindings) {
    if (!bindings.library.providesSymbol('fs_recording_monotonic_us')) {
      throw StateError('Durable recording capture is unavailable');
    }
    return bindings.library.lookupFunction<Int64 Function(), int Function()>(
      'fs_recording_monotonic_us',
    )();
  }

  final NativeLibrary _bindings;
  final int _handle;
  final String sessionId, generation, _spanId;
  final AudioSource source;
  final int span;
  RecordingCaptureSnapshot? _last;
  Future<void>? _finished, _retired;
  bool _finishRequested = false;
  bool _finishAcknowledged = false, _polledAfterFinish = false;

  RecordingCaptureSnapshot poll() {
    if (_retired != null) throw StateError('Recording capture is retired');
    final lib = _bindings.library;
    final poll = lib
        .lookupFunction<
          Pointer<Utf8> Function(Uint64),
          Pointer<Utf8> Function(int)
        >('fs_owned_capture_recording_poll');
    final free = lib
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('fs_string_free');
    final value = poll(_handle);
    if (value == nullptr) {
      throw StateError('Recording capture metadata is unavailable');
    }
    try {
      final encoded = value.toDartString();
      if (encoded.length > 65536) {
        throw const FormatException('Unbounded recording capture metadata');
      }
      final snapshot = RecordingCaptureSnapshot.fromJson(
        _object(jsonDecode(encoded)),
      );
      if (snapshot.sessionId != sessionId ||
          snapshot.generation != generation ||
          snapshot.source != source ||
          snapshot.span != span) {
        throw const FormatException('Recording capture owner changed');
      }
      _polledAfterFinish = _finishAcknowledged;
      return _last = snapshot;
    } finally {
      free(value);
    }
  }

  /// Control/consent/route events share the legacy queue; PCM is deliberately
  /// ignored by the durable owner. Publication metadata has its own poll.
  Map<String, dynamic>? pollEvent() {
    if (_retired != null) throw StateError('Recording capture is retired');
    final poll = _bindings.library
        .lookupFunction<
          Pointer<Utf8> Function(Uint64, Int32),
          Pointer<Utf8> Function(int, int)
        >('fs_owned_event_poll');
    final free = _bindings.library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('fs_string_free');
    final value = poll(_handle, 0);
    if (value == nullptr) return null;
    try {
      final encoded = value.toDartString();
      if (encoded.length > 1048576) {
        throw const FormatException('Unbounded recording control event');
      }
      return _object(jsonDecode(encoded));
    } finally {
      free(value);
    }
  }

  int setEchoCancellation(bool enabled) {
    if (_finishRequested || _retired != null) {
      throw StateError('Recording capture is finishing');
    }
    _bindings.lifetime.ensureAdmission();
    return _bindings.library
        .lookupFunction<Int32 Function(Uint64, Int32), int Function(int, int)>(
          'fs_owned_capture_set_echo_cancellation',
        )(_handle, enabled ? 1 : 0);
  }

  Future<void> reserve(List<AudioChunkPublication> values) async {
    final owner = _last;
    if (_finishRequested ||
        owner == null ||
        values.any((value) => value.spanId != _spanId)) {
      throw StateError('Recording capture is not reservable');
    }
    _bindings.lifetime.ensureAdmission();
    final json = jsonEncode({
      'chunk_ids': _reservations(
        values,
        owner.sessionId,
        owner.generation,
        owner.source,
      ),
    }).toNativeUtf8();
    try {
      final reserve = _bindings.library
          .lookupFunction<
            Uint64 Function(Uint64, Pointer<Utf8>),
            int Function(int, Pointer<Utf8>)
          >('fs_owned_capture_reserve_async');
      if (await _bindings.lifetime.observeOperation(reserve(_handle, json)) !=
          1) {
        throw StateError(
          'Recording reservations failed; reconcile published intents before retry',
        );
      }
    } finally {
      calloc.free(json);
    }
  }

  Future<void> finish() {
    _finishRequested = true;
    return _finished ??= () async {
      if (await _bindings.lifetime.request(
            'fs_capture_finish_async',
            _handle,
          ) !=
          1) {
        throw StateError('Recording capture could not finish');
      }
      _finishAcknowledged = true;
    }();
  }

  /// The service persists all notices, polls the sealed route once more until
  /// empty, and only then releases the physical writer and its pinned mapping.
  Future<void> retire() {
    final existing = _retired;
    if (existing != null) return existing;
    if (!_finishAcknowledged ||
        !_polledAfterFinish ||
        _last == null ||
        !const {
          RecordingCapturePhase.sealed,
          RecordingCapturePhase.failed,
        }.contains(_last!.phase) ||
        _last!.chunks.isNotEmpty ||
        _last!.readyChunks != 0 ||
        _last!.captureActive) {
      throw StateError(
        'Finish and drain recording publications before retirement',
      );
    }
    return _retired = () async {
      await _finished;
      await _bindings.lifetime.retire('fs_capture_retire', _handle);
    }();
  }
}
