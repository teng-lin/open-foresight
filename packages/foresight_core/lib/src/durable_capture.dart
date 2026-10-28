import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'application_services/recording_audio_work.dart';
import 'audio_models.dart';
import 'native_lifetime.dart';
import 'persistence/recording_media.dart';
import 'recording_capture.dart';
import 'rpc_error.dart';
import 'service_diagnostics.dart';
import 'diagnostics/events.dart';

abstract interface class DurableCaptureRoute {
  RecordingCaptureSnapshot poll();
  Map<String, dynamic>? pollEvent();
  int setEchoCancellation(bool enabled);
  Future<void> reserve(List<AudioChunkPublication> values);
  Future<void> finish();
  Future<void> retire();
}

abstract interface class DurableCapturePlatform {
  int monotonicUs();
  Future<DurableCaptureRoute> start({
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
    required bool echoCancellation,
  });
}

final class NativeDurableCapturePlatform implements DurableCapturePlatform {
  NativeDurableCapturePlatform(this.bindings);
  final NativeLibrary bindings;
  @override
  int monotonicUs() => RecordingCapture.monotonicUs(bindings);
  @override
  Future<DurableCaptureRoute> start({
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
    required bool echoCancellation,
  }) async => _NativeRoute(
    await RecordingCapture.start(
      bindings: bindings,
      target: target,
      source: source,
      directory: directory,
      sessionId: sessionId,
      generation: generation,
      span: span,
      originUs: originUs,
      sourceSample: sourceSample,
      reservations: reservations,
      mayStart: mayStart,
      echoCancellation: echoCancellation,
    ),
  );
}

final class _NativeRoute implements DurableCaptureRoute {
  _NativeRoute(this.route);
  final RecordingCapture route;
  @override
  RecordingCaptureSnapshot poll() => route.poll();
  @override
  Map<String, dynamic>? pollEvent() => route.pollEvent();
  @override
  int setEchoCancellation(bool enabled) => route.setEchoCancellation(enabled);
  @override
  Future<void> reserve(List<AudioChunkPublication> values) =>
      route.reserve(values);
  @override
  Future<void> finish() => route.finish();
  @override
  Future<void> retire() => route.retire();
}

final class _Route {
  _Route(this.source, this.owner, this.nextSequence);
  final AudioSource source;
  final DurableCaptureRoute owner;
  int nextSequence;
  RecordingCaptureSnapshot? snapshot;
  final notices = <RecordingChunkNotice>[];
  Future<void>? reserving, publishing;
}

/// Service-owned capture and publication fences, independent of ASR progress.
/// At most16 initial/resupply reservations and128 pending descriptors per source;
/// PCM is not accumulated or scheduled in Dart; bounded legacy events are discarded.
final class DurableCaptureController {
  DurableCaptureController({
    required this.media,
    required this.meetingId,
    required this.modelRevision,
    required this.work,
    required this.platform,
    required this.now,
    required this.createTimer,
    required this.state,
    required this.changed,
  });
  final RecordingMedia media;
  final int meetingId;
  final String modelRevision;
  final RecordingAudioWorkPort work;
  final DurableCapturePlatform platform;
  final DateTime Function() now;
  final Timer Function(Duration, void Function()) createTimer;
  final void Function(String) state;
  final void Function() changed;
  final _diagnostics = captureServiceDiagnosticEmitter();
  AudioSession? session;
  AudioSpan? _span;
  final _routes = <_Route>[];
  final _nextSequences = <int>[0, 0];
  bool _spanPrepared = false, _spanPublicationFailed = false;
  final sampleCounts = <int>[0, 0];
  final peakVolumes = <double>[0, 0], currentVolumes = <double>[0, 0];
  final _targets = <String>[];
  final _echo = <String, dynamic>{};
  Timer? _timer;
  Future<void>? _starting, _sealing, _stopping, _closed;
  bool _stopRequested = false,
      _disposed = false,
      paused = false,
      finishing = false;
  bool _echoRequested = false, _everAcquired = false;
  int _originUs = 0,
      _playbackEndUs = 0,
      _spanPublishedEndUs = 0,
      _activityCaptureUs = 0;
  int? _acquiredThroughUs;
  int? get acquiredThroughUs => _acquiredThroughUs;
  bool get pausing => _sealing != null && !_stopRequested;
  DateTime? _lastActivity;
  Object? _failure;
  StackTrace? _failureStack;
  String lastError = '', backgroundError = '';
  bool get starting =>
      _starting != null || (!_everAcquired && !paused && !_stopRequested);
  bool get captureActive =>
      !_stopRequested &&
      _starting == null &&
      _sealing == null &&
      !paused &&
      !finishing &&
      _failure == null &&
      _routes.any((route) => route.snapshot?.captureActive == true);
  DateTime get lastAudioActivity => _lastActivity ?? now();
  Duration get inactiveFor => Duration(
    microseconds: math.max(
      0,
      platform.monotonicUs() - _originUs - _activityCaptureUs,
    ),
  );
  String? get sessionId => session?.id;
  bool get hasCaptureOwnership => _routes.isNotEmpty;
  int get elapsedMs {
    final span = _span;
    if (span == null || _acquiredThroughUs == null) {
      return _playbackEndUs ~/ 1000;
    }
    return (_playbackEndUs +
            math.max(0, _acquiredThroughUs! - span.captureStartUs)) ~/
        1000;
  }

  Map<String, dynamic> get echoCancellationState => {
    ..._echo,
    'requested': _echoRequested,
    'active': captureActive && _echo['active'] == true,
  };

  Future<void> start({
    bool playback = true,
    String microphoneTarget = 'auto',
    String playbackTarget = 'auto',
    bool echoCancellation = false,
  }) {
    if (session != null || _starting != null || _stopRequested) {
      throw StateError('A durable recording is already active');
    }
    try {
      _targets.addAll([microphoneTarget, if (playback) playbackTarget]);
      _echoRequested = echoCancellation;
      _lastActivity = now();
      _originUs = platform.monotonicUs();
      media.admitNewCapture();
      session = media.audio.createSession(
        meetingId: meetingId,
        startedWallMs: now().millisecondsSinceEpoch,
      );
      return _starting = _startSpan().whenComplete(() => _starting = null);
    } catch (error, stack) {
      _fail(error, stack, stage: DiagnosticCaptureStage.start);
      rethrow;
    }
  }

  Future<void> _startSpan() async {
    try {
      _requireAdmission();
      final span = _span = media.audio.startSpan(
        session!.id,
        captureStartUs: math.max(0, platform.monotonicUs() - _originUs),
        playbackStartUs: _playbackEndUs,
        wallAnchorMs: now().millisecondsSinceEpoch,
      );
      _acquiredThroughUs = null;
      _spanPublishedEndUs = span.captureStartUs;
      _activityCaptureUs = math.max(0, platform.monotonicUs() - _originUs);
      _everAcquired = false;
      _spanPrepared = false;
      _spanPublicationFailed = false;
      final initial = <AudioSource, List<AudioChunkPublication>>{};
      for (var index = 0; index < _targets.length; ++index) {
        final source = AudioSource.values[index];
        initial[source] = media.preallocate(
          span: span,
          source: source,
          firstSequence: _nextSequences[index],
        );
        _nextSequences[index] += initial[source]!.length;
      }
      work.prepareSpan(
        span,
        modelRevision: modelRevision,
        sourceStarts: Map.unmodifiable({
          for (final source in initial.keys) source: sampleCounts[source.index],
        }),
      );
      _spanPrepared = true;
      final directory = media.sessionDirectory(session!.id);
      for (final entry in initial.entries) {
        _requireAdmission();
        final route = await platform.start(
          target: _targets[entry.key.index],
          source: entry.key,
          directory: directory,
          sessionId: session!.id,
          generation: session!.storageGeneration,
          span: span.ordinal,
          originUs: _originUs,
          sourceSample: sampleCounts[entry.key.index],
          reservations: entry.value,
          mayStart: _mayAdmit,
          echoCancellation:
              entry.key == AudioSource.microphone && _echoRequested,
        );
        _routes.add(_Route(entry.key, route, _nextSequences[entry.key.index]));
      }
      _requireAdmission();
      paused = false;
      _lastActivity = now();
      _emit('Starting audio capture');
      poll();
      _schedule();
    } catch (error, stack) {
      if (!_stopRequested) {
        _fail(error, stack, stage: DiagnosticCaptureStage.start);
      }
      try {
        await _finishSpan('interrupted');
      } catch (_) {}
      rethrow;
    }
  }

  bool _mayAdmit() => !_stopRequested && !_disposed && _failure == null;
  void _requireAdmission() {
    if (!_mayAdmit()) {
      throw RpcError(RpcErrorCode.cancelled, 'Recording start cancelled');
    }
  }

  void _schedule() {
    if (_stopRequested ||
        paused ||
        _disposed ||
        _sealing != null ||
        _timer != null) {
      return;
    }
    _timer = createTimer(const Duration(milliseconds: 50), () {
      _timer = null;
      poll();
      _schedule();
    });
  }

  /// Independent metadata cadence: neither filesystem hashing, resupply fsync
  /// nor background speech work holds this poll or the fresh-frame meters.
  void poll() {
    if (_disposed) return;
    try {
      for (final route in List.of(_routes)) {
        _accept(route, route.owner.poll());
        for (var index = 0; index < 16; ++index) {
          final event = route.owner.pollEvent();
          if (event == null) break;
          if (event['type'] == 'echo_cancellation' &&
              route.source == AudioSource.microphone) {
            _echo
              ..clear()
              ..addAll(event)
              ..['pending'] = false;
            if ((event['fallback_status'] != null &&
                    event['fallback_status'] != 0) ||
                (event['fallback_reason'] as String?)?.isNotEmpty == true) {
              _emit(
                'Echo cancellation unavailable; continuing with standard microphone capture.',
              );
            } else if (event['restart_required'] == true) {
              _emit('Restart recording to enable echo cancellation.');
            }
          } else if (event['type'] == 'gap' &&
              event['reason'] != 'capture_buffer_overflow') {
            currentVolumes[route.source.index] = 0;
            if (route.source == AudioSource.microphone) {
              _echo['active'] = false;
              _echo['pending'] = _echoRequested;
            }
            _emit(
              'Audio route interrupted; retained recording preserves the gap',
            );
          } else if (event['type'] == 'state' && event['message'] is String) {
            _emit(event['message'] as String);
          }
        }
        _replenish(route);
      }
      changed();
    } catch (error, stack) {
      _fail(error, stack, stage: DiagnosticCaptureStage.poll);
    }
  }

  void _accept(_Route route, RecordingCaptureSnapshot snapshot) {
    if (snapshot.sessionId != session!.id ||
        snapshot.generation != session!.storageGeneration ||
        snapshot.span != _span!.ordinal ||
        snapshot.source != route.source) {
      throw StateError('Recording capture identity changed');
    }
    final previous = route.snapshot;
    final oldSamples = sampleCounts[route.source.index];
    if (snapshot.sourceSample < sampleCounts[route.source.index]) {
      throw StateError('Recording sample count moved backwards');
    }
    route.snapshot = snapshot;
    sampleCounts[route.source.index] = snapshot.sourceSample;
    currentVolumes[route.source.index] = snapshot.currentVolume;
    peakVolumes[route.source.index] = math.max(
      peakVolumes[route.source.index],
      snapshot.peakVolume,
    );
    final through = snapshot.acquiredThroughUs;
    if (through != null) {
      if (through < _span!.captureStartUs ||
          through < (previous?.acquiredThroughUs ?? through)) {
        throw StateError('Recording acquisition clock moved backwards');
      }
      _acquiredThroughUs = math.max(_acquiredThroughUs ?? through, through);
    }
    if (snapshot.sourceSample > oldSamples &&
        snapshot.lastVoiceCaptureUs != null &&
        snapshot.lastVoiceCaptureUs! > (previous?.lastVoiceCaptureUs ?? -1)) {
      _activityCaptureUs = math.max(
        _activityCaptureUs,
        snapshot.lastVoiceCaptureUs!,
      );
      _lastActivity = now().subtract(inactiveFor);
    }
    if (route.notices.length + snapshot.chunks.length > 128) {
      throw StateError(
        'Recording publication validation backlog exceeded its bound',
      );
    }
    route.notices.addAll(snapshot.chunks);
    _publish(route);
    if (snapshot.captureActive && !_everAcquired) {
      _everAcquired = true;
      media.audio.setCaptureState(session!.id, AudioCaptureState.recording);
      _emit('Recording · transcription continues in the background');
    }
    final quality = AudioSourceClockQuality.values.byName(
      snapshot.clockQuality.name,
    );
    if (quality != AudioSourceClockQuality.unavailable) {
      media.audio.recordSourceClock(
        _span!.id,
        route.source,
        quality,
        // The route's first clock provenance applies to all its captured
        // samples in this span, including audio published after this poll.
        observedCaptureUs:
            previous == null ||
                previous.clockQuality == RecordingClockQuality.unavailable
            ? _span!.captureStartUs
            : math.max(_span!.captureStartUs, through ?? _span!.captureStartUs),
        uncertaintyUs: snapshot.uncertaintyUs,
      );
    }
    if (snapshot.error != null) {
      _fail(
        StateError(snapshot.error!),
        StackTrace.current,
        stage: DiagnosticCaptureStage.nativeRoute,
      );
    }
  }

  void _publish(_Route route) {
    if (route.publishing != null || route.notices.isEmpty) return;
    route.publishing = () async {
      while (route.notices.isNotEmpty) {
        final notice = route.notices.removeAt(0);
        try {
          final chunk = await media.publish(notice);
          _spanPublishedEndUs = math.max(
            _spanPublishedEndUs,
            chunk.captureEndUs,
          );
          _hint(() => work.published(chunk));
        } catch (error, stack) {
          _spanPublicationFailed = true;
          _fail(error, stack, stage: DiagnosticCaptureStage.publish);
        }
      }
    }().whenComplete(() => route.publishing = null);
  }

  void _replenish(_Route route) {
    final snapshot = route.snapshot;
    if (!_mayAdmit() ||
        _sealing != null ||
        paused ||
        snapshot == null ||
        !snapshot.ready ||
        route.reserving != null ||
        snapshot.reservedChunks > 8 ||
        route.notices.length >= 32) {
      return;
    }
    final count = math.min(16, 64 - snapshot.outstandingChunks);
    if (count <= 0) return;
    final values = media.preallocate(
      span: _span!,
      source: route.source,
      firstSequence: route.nextSequence,
      count: count,
    );
    route.nextSequence += count;
    _nextSequences[route.source.index] = route.nextSequence;
    route.reserving = route.owner
        .reserve(values)
        .catchError((Object error, StackTrace stack) {
          if (_sealing == null && !_stopRequested) {
            _fail(error, stack, stage: DiagnosticCaptureStage.reserve);
          }
        })
        .whenComplete(() => route.reserving = null);
  }

  void setEchoCancellation(bool enabled) {
    final microphone = _routes
        .where((route) => route.source == AudioSource.microphone)
        .firstOrNull;
    var pending = false;
    if (microphone != null) {
      final accepted = microphone.owner.setEchoCancellation(enabled);
      if (enabled && accepted == 0) {
        throw StateError(
          'Echo cancellation is unavailable for this audio route',
        );
      }
      pending = accepted == 1;
    }
    _echoRequested = enabled;
    _echo['pending'] = pending;
    changed();
  }

  Future<void> pause() async {
    if (paused) return;
    if (_stopRequested || _starting != null) {
      throw StateError('Recording cannot pause now');
    }
    try {
      media.audio.setCaptureState(session!.id, AudioCaptureState.pausing);
      await _finishSpan('pause');
      if (_stopRequested || _failure != null) _throwFailure();
      paused = true;
      media.audio.setCaptureState(session!.id, AudioCaptureState.paused);
      _emit('Recording paused');
      changed();
    } catch (error, stack) {
      _fail(error, stack, stage: DiagnosticCaptureStage.pause);
      rethrow;
    }
  }

  Future<void> resume() {
    if (!paused || _stopRequested || _failure != null) {
      throw StateError('Recording cannot resume');
    }
    return _starting = _startSpan().whenComplete(() => _starting = null);
  }

  Future<void> _finishSpan(String reason) => _sealing ??= () async {
    _timer?.cancel();
    _timer = null;
    final span = _span;
    if (span == null) return;
    Object? failure;
    StackTrace? stack;
    final routes = List.of(_routes);
    var acquisitionFenced = true;
    final finishes = [
      for (final route in routes)
        Future<void>.sync(
          route.owner.finish,
        ).then<({Object? error, StackTrace? stack})>(
          (_) => (error: null, stack: null),
          onError: (Object error, StackTrace stack) =>
              (error: error, stack: stack),
        ),
    ];
    for (var index = 0; index < routes.length; ++index) {
      final route = routes[index];
      try {
        final finish = await finishes[index];
        if (finish.error != null) {
          acquisitionFenced = false;
          Error.throwWithStackTrace(finish.error!, finish.stack!);
        }
        await route.reserving;
        for (var attempt = 0; ; ++attempt) {
          final snapshot = route.owner.poll();
          _accept(route, snapshot);
          if (snapshot.chunks.isEmpty && snapshot.readyChunks == 0) break;
          if (attempt >= 3) {
            throw StateError('Recording did not drain after finish');
          }
        }
        await route.publishing;
        await route.owner.retire();
        _routes.remove(route);
      } catch (error, trace) {
        failure ??= error;
        stack ??= trace;
      }
    }
    for (final value in currentVolumes.asMap().keys) {
      currentVolumes[value] = 0;
    }
    // File fsync/validation completion does not extend captured duration.
    final end = math.max(
      _spanPublishedEndUs,
      math.max(span.captureStartUs, _acquiredThroughUs ?? span.captureStartUs),
    );
    if (acquisitionFenced) {
      media.audio.closeSpan(span.id, captureEndUs: end, reason: reason);
      _playbackEndUs = span.playbackStartUs + end - span.captureStartUs;
      _span = null;
      if (failure == null && !_spanPublicationFailed && _spanPrepared) {
        _hint(() => work.spanSealed(media.audio.spans(session!.id).last));
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }().whenComplete(() => _sealing = null);

  Future<void> stop() => _stopping ??= () async {
    _stopRequested = true;
    finishing = true;
    _timer?.cancel();
    try {
      try {
        await _starting;
      } catch (_) {}
      if (session != null) {
        try {
          media.audio.setCaptureState(session!.id, AudioCaptureState.stopping);
        } catch (error, stack) {
          _fail(error, stack, stage: DiagnosticCaptureStage.stopState);
        }
        await _finishSpan(_failure == null ? 'stop' : 'interrupted');
        media.audio.setCaptureState(
          session!.id,
          _failure == null
              ? AudioCaptureState.stopped
              : AudioCaptureState.interrupted,
          stoppedWallMs: now().millisecondsSinceEpoch,
          error: _failure == null ? null : lastError,
        );
        _hint(() => work.captureStopped(media.audio.session(session!.id)!));
      }
      if (_failure != null) _throwFailure();
      _emit('Audio saved · transcription continues in the background');
    } catch (error, stack) {
      _fail(error, stack, stage: DiagnosticCaptureStage.finish);
      if (session != null && _span == null) {
        try {
          if (!media.audio.session(session!.id)!.captureState.terminal) {
            media.audio.setCaptureState(
              session!.id,
              AudioCaptureState.interrupted,
              stoppedWallMs: now().millisecondsSinceEpoch,
              error: lastError,
            );
            _hint(() => work.captureStopped(media.audio.session(session!.id)!));
          }
        } catch (_) {
          /* Preserve the original fence/storage failure. */
        }
      }
      rethrow;
    } finally {
      finishing = false;
    }
  }();

  void _hint(void Function() notify) {
    try {
      notify();
    } catch (error) {
      backgroundError = error.toString();
    }
  }

  void _emit(String value) {
    if (_failure != null) return;
    state(value);
  }

  void _fail(
    Object error,
    StackTrace stack, {
    required DiagnosticCaptureStage stage,
  }) {
    if (_failure != null) return;
    _failure = error;
    _failureStack = stack;
    try {
      _diagnostics?.emit(
        DiagnosticEvent.captureFailed,
        fields: () => {
          DiagnosticField.stage: stage,
          if (error is FileSystemException && error.osError != null)
            DiagnosticField.status: error.osError!.errorCode,
        },
      );
    } catch (_) {
      // Retain the first production failure even if diagnostics cannot accept it.
    }
    currentVolumes.fillRange(0, currentVolumes.length, 0);
    _echo['active'] = false;
    lastError =
        'Capture interrupted: audio storage or capture failed. Saved audio is retained.';
    try {
      state(lastError);
    } catch (_) {}
    try {
      changed();
    } catch (_) {}
    if (!_stopRequested) {
      scheduleMicrotask(() {
        stop().ignore();
      });
    }
  }

  Never _throwFailure() => Error.throwWithStackTrace(
    _failure ?? StateError('Recording stopped'),
    _failureStack ?? StackTrace.current,
  );
  Future<void> get closed => _closed ?? Future.value();
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _closed = stop();
    _closed!.ignore();
  }
}
