import 'rpc_error.dart';
import 'desktop_connection.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'native.dart';
import 'runtime_execution_policy.dart';

class _AudioSegment {
  final int channel, startSamples, sampleRate;
  final Uint8List pcm;
  final bool provisional;
  final int? provisionalEpoch;
  _AudioSegment(
    this.channel,
    this.startSamples,
    this.sampleRate,
    this.pcm,
    this.provisional, [
    this.provisionalEpoch,
  ]);
}

/// Continuous capture with bounded real Whisper jobs. Rolling hypotheses are
/// ephemeral; completed speech segments are committed while capture continues.
class Recording implements RecordingStatus {
  // Resolve each optional native symbol lazily once per loaded library.
  late final _nativeFsCaptureSetEchoCancellation = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('fs_capture_set_echo_cancellation');
  late final _nativeFsEventPoll = lib
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>, Int32),
        Pointer<Utf8> Function(Pointer<Void>, int)
      >('fs_event_poll');
  late final _nativeFsStringFree = lib
      .lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('fs_string_free');
  late final _nativeFsSpeechCreate = lib
      .lookupFunction<CreateNative, CreateDart>('fs_speech_create');
  late final _nativeFsSpeechDestroy = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('fs_speech_destroy');
  late final _nativeFsCaptureStartWithOptions = lib
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Int32, Int32, Int32),
        Pointer<Void> Function(Pointer<Utf8>, int, int, int)
      >('fs_capture_start_with_options');
  late final _nativeFsCaptureStart = lib
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Int32, Int32),
        Pointer<Void> Function(Pointer<Utf8>, int, int)
      >('fs_capture_start');
  late final _nativeFsCaptureStop = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('fs_capture_stop');
  late final _nativeFsCaptureFinish = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('fs_capture_finish');
  late final _nativeFsSpeechPush = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Int16>, Size, Int32),
        int Function(Pointer<Void>, Pointer<Int16>, int, int)
      >('fs_speech_push');
  late final _nativeFsSpeechFinish = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>),
        int Function(Pointer<Void>, Pointer<Utf8>)
      >('fs_speech_finish');

  final DynamicLibrary lib;
  final Duration speechTimeout, stopTimeout;
  final void Function(String) state;
  final void Function(String, int, int, String) transcript;
  final void Function(String, int, int, String)? provisional;
  final void Function(Map<String, dynamic>)? interruption;
  final void Function()? levels;
  @override
  final currentVolumes = <double>[];
  int _lastLevels = 0;
  final captures = <Pointer<Void>>[], speeches = <Pointer<Void>>[];
  final _idleSpeeches = <int, Pointer<Void>>{};
  @override
  final sampleCounts = <int>[];
  @override
  final peakVolumes = <double>[];
  final _buffers = <BytesBuilder>[], _starts = <int>[], _rates = <int>[];
  final _lastVoice = <int>[], _voiced = <bool>[], _nextSnapshot = <int>[];
  final _provisionalEpochs = <int>[];
  final _queues = <List<_AudioSegment>>[];
  final _workers = <int, Future<void>>{};
  Timer? timer;
  bool polling = false;
  @override
  bool finishing = false;
  @override
  bool paused = false;
  bool _echoCancellation = false;
  final _echoState = <String, dynamic>{};
  @override
  Map<String, dynamic> get echoCancellationState => {
    ..._echoState,
    'requested': _echoCancellation,
    'active': !paused && captures.isNotEmpty && _echoState['active'] == true,
  };

  void setEchoCancellation(bool enabled) {
    var pending = false;
    if (!lib.providesSymbol('fs_capture_set_echo_cancellation')) {
      if (enabled) {
        throw StateError(
          'Echo cancellation requires an updated native audio runtime',
        );
      }
    } else if (captures.isNotEmpty) {
      final accepted = _nativeFsCaptureSetEchoCancellation(
        captures.first,
        enabled ? 1 : 0,
      );
      pending = accepted == 1;
      if (accepted == 0 && enabled) {
        throw StateError(
          'Echo cancellation is unavailable for this audio route',
        );
      }
    }
    _echoCancellation = enabled;
    _echoState['pending'] = pending;
    levels?.call();
  }

  final _targets = <String>[];
  String lastError = '', _runtime = '', _model = '';
  @override
  DateTime lastAudioActivity = DateTime.now();
  int _epoch = 0, _transcriptCount = 0;
  Object? _callbackFailure;
  StackTrace? _callbackStack;
  Recording(
    String path,
    this.state,
    this.transcript, {
    this.provisional,
    this.interruption,
    this.levels,
    this.speechTimeout = const Duration(seconds: 60),
    this.stopTimeout = const Duration(seconds: 90),
  }) : lib = DynamicLibrary.open(path);

  Map<String, dynamic>? poll(Pointer<Void> handle) {
    final result = _nativeFsEventPoll(handle, 0);
    if (result == nullptr) return null;
    try {
      return jsonDecode(result.toDartString()) as Map<String, dynamic>;
    } finally {
      _nativeFsStringFree(result);
    }
  }

  Pointer<Void> _speech() {
    final runtime = _runtime.toNativeUtf8(), model = _model.toNativeUtf8();
    try {
      final handle = _nativeFsSpeechCreate(runtime, model);
      if (handle == nullptr) {
        throw StateError('Speech runtime/model unavailable');
      }
      speeches.add(handle);
      return handle;
    } finally {
      calloc.free(runtime);
      calloc.free(model);
    }
  }

  void _releaseSpeech(Pointer<Void> handle) {
    final active = speeches.remove(handle);
    final idle = _idleSpeeches.values.contains(handle);
    _idleSpeeches.removeWhere((_, value) => value == handle);
    if (!active && !idle) return;
    _nativeFsSpeechDestroy(handle);
  }

  void start(
    String runtime,
    String model, {
    bool playback = true,
    String microphoneTarget = 'auto',
    String playbackTarget = 'auto',
    bool echoCancellation = false,
  }) {
    runtime = requireInstalledRuntime(runtime);
    if (captures.isNotEmpty ||
        speeches.isNotEmpty ||
        paused ||
        finishing ||
        _workers.isNotEmpty) {
      throw RpcError(RpcErrorCode.busy, 'A recording is already active');
    }
    if (!File(model).existsSync()) {
      throw StateError('Speech model file is missing: $model');
    }
    if (!File(runtime).existsSync() ||
        File(runtime).statSync().mode & 0x49 == 0) {
      throw StateError('Speech runner is missing or not executable: $runtime');
    }
    _runtime = runtime;
    _model = model;
    _echoCancellation = echoCancellation;
    _echoState.clear();
    _epoch++;
    _transcriptCount = 0;
    lastError = '';
    _callbackFailure = null;
    _callbackStack = null;
    lastAudioActivity = DateTime.now();
    sampleCounts.clear();
    peakVolumes.clear();
    currentVolumes.clear();
    _buffers.clear();
    _starts.clear();
    _rates.clear();
    _lastVoice.clear();
    _voiced.clear();
    _nextSnapshot.clear();
    _provisionalEpochs.clear();
    _queues.clear();
    _targets
      ..clear()
      ..addAll([microphoneTarget, if (playback) playbackTarget]);
    try {
      final probe = _speech();
      _releaseSpeech(probe);
      for (var channel = 0; channel < (playback ? 2 : 1); channel++) {
        final capture = _startCapture(channel);
        captures.add(capture);
        sampleCounts.add(0);
        peakVolumes.add(0);
        currentVolumes.add(0);
        _buffers.add(BytesBuilder(copy: false));
        _starts.add(0);
        _rates.add(48000);
        _lastVoice.add(0);
        _voiced.add(false);
        _nextSnapshot.add(48000 * 5);
        _provisionalEpochs.add(0);
        _queues.add([]);
      }
      state('Listening · live transcription');
      timer = Timer.periodic(const Duration(milliseconds: 20), (_) => drain());
    } catch (_) {
      try {
        dispose();
      } catch (_) {
        // Preserve startup's failure after attempting every owned resource.
      }
      rethrow;
    }
  }

  Pointer<Void> _startCapture(int channel) {
    final target = _targets[channel].toNativeUtf8();
    try {
      if (channel == 0 &&
          _echoCancellation &&
          !lib.providesSymbol('fs_capture_start_with_options')) {
        throw StateError(
          'Echo cancellation requires an updated native audio runtime',
        );
      }
      final capture = channel == 0 && _echoCancellation
          ? _nativeFsCaptureStartWithOptions(target, channel, 48000, 1)
          : _nativeFsCaptureStart(target, channel, 48000);
      if (capture == nullptr) {
        throw StateError(
          'Audio capture unavailable; check device and microphone/system-audio permissions.',
        );
      }
      return capture;
    } finally {
      calloc.free(target);
    }
  }

  /// Stop acquisition, retain and finalize pre-pause PCM, and release devices.
  /// Speech workers may finish their existing segments while capture is paused.
  void pause() {
    if (finishing) {
      throw RpcError(RpcErrorCode.busy, 'Transcription is finalizing');
    }
    if (paused) return;
    if (captures.isEmpty) {
      throw RpcError(RpcErrorCode.notFound, 'No active recording');
    }
    timer?.cancel();
    _finishCapture();
    for (var channel = 0; channel < _buffers.length; channel++) {
      _flush(channel);
      currentVolumes[channel] = 0;
      _provisionalEpochs[channel]++;
      provisional?.call('', 0, 0, channel == 0 ? 'microphone' : 'playback');
    }
    paused = true;
    state('Transcription paused');
    levels?.call();
  }

  void resume() {
    if (finishing) {
      throw RpcError(RpcErrorCode.busy, 'Transcription is finalizing');
    }
    if (!paused) throw StateError('Recording is not paused');
    _echoState
      ..clear()
      ..['active'] = false
      ..['pending'] = _echoCancellation;
    try {
      for (var channel = 0; channel < _targets.length; channel++) {
        captures.add(_startCapture(channel));
      }
    } catch (_) {
      try {
        _stopCaptures();
      } catch (_) {
        // Cleanup cannot replace the failed route's original error.
      }
      try {
        state('Resume failed; transcription remains paused');
      } catch (_) {
        // Keep the route failure if its presentation callback also fails.
      }
      rethrow;
    }
    paused = false;
    lastAudioActivity = DateTime.now();
    state('Listening · live transcription');
    timer = Timer.periodic(const Duration(milliseconds: 20), (_) => drain());
  }

  void _finishCapture() {
    Object? failure;
    StackTrace? stack;
    try {
      for (final capture in captures) {
        _nativeFsCaptureFinish(capture);
      }
      drain(flushAll: true);
    } catch (error, trace) {
      failure = error;
      stack = trace;
    }
    try {
      _stopCaptures();
    } catch (error, trace) {
      failure ??= error;
      stack ??= trace;
    }
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }

  void _stopCaptures() {
    // Detach before cleanup so a failing observer cannot release a handle twice.
    final owned = captures.toList();
    captures.clear();
    Object? failure;
    StackTrace? stack;
    for (final capture in owned) {
      try {
        _nativeFsCaptureStop(capture);
      } catch (error, trace) {
        failure ??= error;
        stack ??= trace;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }

  void _rememberCallbackFailure(Object error, StackTrace stack) {
    _callbackFailure ??= error;
    _callbackStack ??= stack;
    if (lastError.isEmpty) lastError = 'Recording callback failed';
    timer?.cancel();
    try {
      _stopCaptures();
    } catch (_) {
      // Keep the original callback failure after attempting every capture.
    }
  }

  void drain({bool flushAll = false}) {
    if (polling) return;
    polling = true;
    try {
      for (var channel = 0; channel < captures.length; channel++) {
        for (
          var n = 0;
          (flushAll || n < 50) && channel < captures.length;
          n++
        ) {
          final event = poll(captures[channel]);
          if (event == null) break;
          if (event['type'] == 'echo_cancellation' && channel == 0) {
            _echoState
              ..clear()
              ..addAll(event)
              ..['pending'] = false;
            if ((event['fallback_status'] != null &&
                    event['fallback_status'] != 0) ||
                (event['fallback_reason'] as String?)?.isNotEmpty == true) {
              state(
                'Echo cancellation unavailable; continuing with standard microphone capture.',
              );
            } else if (event['restart_required'] == true) {
              state('Restart recording to enable echo cancellation.');
            }
            levels?.call();
            continue;
          }
          if (event['type'] == 'gap') {
            _flush(channel);
            _captureInterrupted(
              channel,
              reconnecting: true,
              processingInterrupted:
                  event['reason'] != 'capture_buffer_overflow',
            );
            final gap = {
              ...event,
              'source': channel == 0 ? 'microphone' : 'playback',
            };
            if (lastError.isEmpty) {
              state(
                'Capture gap: ${event['reason']}; resuming live transcription',
              );
            }
            interruption?.call(gap);
            continue;
          }
          if (event['type'] == 'error' || event['type'] == 'state') {
            if (event['type'] == 'error' ||
                event['state'] == 'failed' ||
                event['state'] == 'stopped') {
              _flush(channel);
              _captureInterrupted(channel, reconnecting: false);
            }
            if (event['type'] == 'error' || event['state'] == 'failed') {
              final source = channel == 0 ? 'Microphone' : 'Playback';
              lastError =
                  '$source capture failed: ${event['message'] ?? 'Capture unavailable'}';
              state(lastError);
            } else if (lastError.isEmpty) {
              // The native terminal sequence is failed -> stopped. Keep the
              // failure visible until Stop, including when a peer channel
              // continues to emit ordinary connecting/capturing states.
              state('${event['message'] ?? event['state']}');
            }
            continue;
          }
          if (event['type'] != 'pcm') continue;
          final pcm = base64Decode(event['data'] as String);
          final rate = (event['sampleRate'] as num).toInt();
          if (rate != _rates[channel]) {
            _flush(channel);
            _rates[channel] = rate;
            _nextSnapshot[channel] = rate * 5;
          }
          sampleCounts[channel] += pcm.length ~/ 2;
          final volume = (event['volume'] as num).toDouble();
          currentVolumes[channel] = volume;
          if (volume > peakVolumes[channel]) peakVolumes[channel] = volume;
          if (volume > .003) {
            lastAudioActivity = DateTime.now();
            _voiced[channel] = true;
            _lastVoice[channel] = sampleCounts[channel];
          }
          _buffers[channel].add(pcm);
          final length = _buffers[channel].length ~/ 2;
          if (length >= rate * 20 ||
              _voiced[channel] &&
                  length >= rate &&
                  sampleCounts[channel] - _lastVoice[channel] >= rate) {
            _flush(channel);
          } else if (_voiced[channel] && length >= _nextSnapshot[channel]) {
            _nextSnapshot[channel] = length + rate * 4;
            // Snapshots never queue behind final work; capture itself keeps running.
            if (!_workers.containsKey(channel) &&
                _queues[channel].isEmpty &&
                provisional != null) {
              _enqueue(
                _AudioSegment(
                  channel,
                  _starts[channel],
                  rate,
                  _buffers[channel].toBytes(),
                  true,
                  _provisionalEpochs[channel],
                ),
              );
            }
          }
        }
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastLevels >= 100) {
        _lastLevels = now;
        levels?.call();
      }
    } catch (error, stack) {
      _rememberCallbackFailure(error, stack);
    } finally {
      polling = false;
    }
  }

  void _captureInterrupted(
    int channel, {
    required bool reconnecting,
    bool processingInterrupted = true,
  }) {
    currentVolumes[channel] = 0;
    _provisionalEpochs[channel]++;
    provisional?.call('', 0, 0, channel == 0 ? 'microphone' : 'playback');
    if (channel == 0 && processingInterrupted) {
      // A live handle can outlast its audio engine during recovery or failure.
      // Only a fresh native processing event can establish active AEC again.
      _echoState['active'] = false;
      _echoState['pending'] = reconnecting && _echoCancellation;
    }
    levels?.call();
  }

  void _flush(int channel) {
    final pcm = _buffers[channel].takeBytes();
    if (_voiced[channel] && pcm.isNotEmpty) {
      _enqueue(
        _AudioSegment(channel, _starts[channel], _rates[channel], pcm, false),
      );
    }
    _starts[channel] = sampleCounts[channel];
    _voiced[channel] = false;
    _nextSnapshot[channel] = _rates[channel] * 5;
  }

  void _enqueue(_AudioSegment segment) {
    final queue = _queues[segment.channel];
    if (queue.length >= 4) {
      lastError =
          'Speech recognition cannot keep up with capture. Stop recording and retry with a faster model.';
      state(lastError);
      // Preserve the new segment in memory; stop acquisition instead of losing speech.
      timer?.cancel();
      for (final capture in captures) {
        _nativeFsCaptureStop(capture);
      }
      captures.clear();
    }
    queue.add(segment);
    if (_workers.containsKey(segment.channel)) return;
    final epoch = _epoch;
    final future = _processChannel(segment.channel, epoch);
    _workers[segment.channel] = future;
    unawaited(
      future.whenComplete(() {
        // Removing the map entry returns the task already observed by this worker.
        // ignore: discarded_futures
        if (epoch == _epoch) _workers.remove(segment.channel);
      }),
    );
  }

  Future<void> _processChannel(int channel, int epoch) async {
    // Deferring prevents synchronous failure from racing worker registration.
    await Future<void>.delayed(Duration.zero);
    while (epoch == _epoch && _queues[channel].isNotEmpty) {
      final segment = _queues[channel].removeAt(0);
      Pointer<Void>? handle;
      var reusable = false;
      try {
        handle = _idleSpeeches.remove(channel);
        if (handle == null) {
          handle = _speech();
        } else {
          speeches.add(handle);
        }
        final samples = calloc<Int16>(segment.pcm.length ~/ 2);
        try {
          final bytes = ByteData.sublistView(segment.pcm);
          for (var i = 0; i < segment.pcm.length ~/ 2; i++) {
            samples[i] = bytes.getInt16(i * 2, Endian.little);
          }
          final rc = _nativeFsSpeechPush(
            handle,
            samples,
            segment.pcm.length ~/ 2,
            segment.sampleRate,
          );
          if (rc != 0) throw StateError('ASR buffer rejected');
        } finally {
          calloc.free(samples);
        }
        final request = 'live-$channel-${DateTime.now().microsecondsSinceEpoch}'
            .toNativeUtf8();
        try {
          if (_nativeFsSpeechFinish(handle, request) != 0) {
            throw StateError('Speech request rejected');
          }
        } finally {
          calloc.free(request);
        }
        String? failure;
        final deadline = DateTime.now().add(speechTimeout);
        while (epoch == _epoch) {
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('Speech worker timed out', speechTimeout);
          }
          final event = poll(handle);
          if (event == null) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            continue;
          }
          if (event['type'] == 'state' && event['message'] is String) {
            state(event['message'] as String);
          }
          if (event['type'] == 'error') failure = event['message'].toString();
          if (event['type'] == 'transcript') {
            final text = (event['text'] as String).trim();
            if (text.isNotEmpty && text != '[BLANK_AUDIO]') {
              final start = segment.startSamples * 1000 ~/ segment.sampleRate;
              final end =
                  start +
                  (segment.pcm.length ~/ 2) * 1000 ~/ segment.sampleRate;
              final source = channel == 0 ? 'microphone' : 'playback';
              if (segment.provisional) {
                if (!paused &&
                    segment.provisionalEpoch == _provisionalEpochs[channel]) {
                  provisional?.call(text, start, end, source);
                }
              } else {
                _transcriptCount++;
                transcript(text, start, end, source);
                provisional?.call('', start, end, source);
              }
            }
          }
          if (event['type'] == 'done') {
            if (event['status'] != 'completed') {
              throw StateError(
                'ASR ${event['status']}: ${failure ?? 'runner failed'}',
              );
            }
            reusable = true;
            break;
          }
        }
      } catch (error, stack) {
        if (epoch == _epoch) {
          lastError = error.toString();
          try {
            state('Live transcription failed: $lastError');
            if (!segment.provisional) {
              interruption?.call({
                'reason': 'speech_recognition_error',
                'message': lastError,
                'discarded_bytes': segment.pcm.length,
                'source': channel == 0 ? 'microphone' : 'playback',
              });
            }
          } catch (_) {
            // Reporting must not replace the producer's original failure or
            // leave acquisition running after its observer stopped working.
            _rememberCallbackFailure(error, stack);
          }
        }
      } finally {
        if (handle != null) {
          if (reusable && epoch == _epoch) {
            speeches.remove(handle);
            _idleSpeeches[channel] = handle;
          } else {
            _releaseSpeech(handle);
          }
        }
      }
    }
  }

  Future<void> stop() async {
    if (finishing) {
      throw RpcError(RpcErrorCode.busy, 'Transcription is already in progress');
    }
    await _stop();
  }

  Future<void> _stop() async {
    finishing = true;
    final epoch = _epoch;
    timer?.cancel();
    Object? failure;
    StackTrace? failureStack;
    try {
      // All acquisition, drain and observer calls belong inside the cleanup
      // boundary, including failures before the first await.
      _finishCapture();
      for (var channel = 0; channel < _buffers.length; channel++) {
        _flush(channel);
      }
      state('Finalizing live transcript');
      final deadline = DateTime.now().add(stopTimeout);
      while (_workers.isNotEmpty && epoch == _epoch) {
        final remaining = deadline.difference(DateTime.now());
        try {
          if (remaining <= Duration.zero) {
            throw TimeoutException(
              'Speech finalization timed out',
              stopTimeout,
            );
          }
          await Future.wait(_workers.values.toList()).timeout(remaining);
        } on TimeoutException catch (error, stack) {
          lastError =
              'Speech finalization timed out; committed transcript retained';
          try {
            interruption?.call({
              'reason': 'speech_stop_timeout',
              'discarded_bytes': 0,
              'source': 'speech',
            });
            state(lastError);
          } catch (_) {
            _rememberCallbackFailure(error, stack);
          }
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }
      if (epoch != _epoch) {
        throw RpcError(RpcErrorCode.cancelled, 'Recording cancelled');
      }
      if (_callbackFailure != null) {
        Error.throwWithStackTrace(_callbackFailure!, _callbackStack!);
      }
      if (lastError.isNotEmpty) throw StateError(lastError);
      state(
        _transcriptCount == 0
            ? 'No speech detected. Check microphone mute and playback.'
            : 'Transcript saved',
      );
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      final producers = _workers.values.toList();
      try {
        if (epoch == _epoch) dispose();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
      try {
        // dispose invalidates their epoch and releases native handles first.
        // Retain actual producer completion rather than just clearing the map.
        await Future.wait(producers);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      } finally {
        finishing = false;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  @override
  void dispose() {
    _epoch++;
    paused = false;
    timer?.cancel();
    Object? failure;
    StackTrace? stack;
    void release(void Function() operation) {
      try {
        operation();
      } catch (error, trace) {
        failure ??= error;
        stack ??= trace;
      }
    }

    release(_stopCaptures);
    for (final speech in {...speeches, ..._idleSpeeches.values}) {
      release(() => _releaseSpeech(speech));
    }
    _workers.clear();
    for (final queue in _queues) {
      queue.clear();
    }
    for (final buffer in _buffers) {
      buffer.clear();
    }
    if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  }
}
