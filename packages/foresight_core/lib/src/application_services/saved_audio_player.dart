import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../audio_presentation.dart';
import '../recording_playback.dart';
import '../rpc_error.dart';
import 'audio_playback_source.dart';

/// A service-owned player. Device output uses a software-consumed playhead;
/// underrun zeros do not advance it. Pause/seek joins old decode and output
/// owners before admitting replacements. At most one five-second PCM window
/// and the native bounded queue are held, independent of meeting duration.
final class SavedAudioPlayer {
  SavedAudioPlayer({
    required this.openSource,
    required this.openOutput,
    required this.changed,
  });
  final Future<AudioPlaybackSource> Function(
    String sessionId,
    bool Function() current,
  )
  openSource;
  final Future<PcmPlaybackOutput> Function(
    int generation,
    bool Function() current,
  )
  openOutput;
  final void Function() changed;
  String? sessionId;
  String _error = '';
  MeetingAudioPlaybackState _state = MeetingAudioPlaybackState.idle;
  AudioPlaybackSource? _source;
  PcmPlaybackOutput? _output;
  Timer? _timer;
  Int16List? _pcm;
  int _pcmOffset = 0,
      _nextFrame = 0,
      _baseFrame = 0,
      _positionFrame = 0,
      _totalFrames = 0;
  int _intent = 0, _generation = 0;
  Future<void> _tail = Future.value();
  Future<void>? _pumping, _closing;
  bool _closed = false, _poisoned = false;
  bool get restartRequired => _poisoned;
  bool get busy => _source != null || _output != null || _pumping != null;
  AudioPlaybackPresentation get presentation => AudioPlaybackPresentation(
    state: _state,
    positionUs: _positionFrame * 1000000 ~/ 48000,
    error: _error,
  );

  void _notify() {
    try {
      changed();
    } catch (_) {
      /* Observers do not own audio. */
    }
  }

  bool _owns(int intent) => !_closed && !_poisoned && intent == _intent;
  void _check(int intent, bool Function() current) {
    if (!_owns(intent) || !current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Audio playback cancelled');
    }
  }

  int _withdraw() {
    final intent = ++_intent;
    _timer?.cancel();
    _timer = null;
    try {
      _source?.cancel();
    } catch (_) {
      /* close still observes actual exit. */
    }
    // Request physical stop immediately even when an earlier command is still
    // waiting for decode/start. close is coalesced by the native output owner.
    _output?.close().ignore();
    return intent;
  }

  Future<void> _enqueue(
    int intent,
    bool Function() current,
    Future<void> Function() action,
  ) {
    final operation = _tail.then((_) async {
      try {
        _check(intent, current);
        await action();
      } catch (_) {
        await _stopOwners();
        if (_owns(intent)) {
          _state = MeetingAudioPlaybackState.failed;
          _error = 'Saved audio playback needs attention';
          _notify();
        }
        rethrow;
      }
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> play(String session, {required bool Function() current}) {
    final same = sessionId == session;
    if (same && _state == MeetingAudioPlaybackState.playing) {
      return Future.value();
    }
    final start = same && _positionFrame < _totalFrames ? _positionFrame : 0;
    final intent = _withdraw();
    return _enqueue(
      intent,
      current,
      () => _start(session, start, intent, current),
    );
  }

  Future<void> pause(String session, {required bool Function() current}) {
    if (sessionId != session) {
      return Future.error(StateError('This recording is not playing'));
    }
    try {
      _samplePosition();
    } catch (_) {
      // Stop still fences a backend that has already reported an error.
    }
    final intent = _withdraw();
    return _enqueue(intent, current, () async {
      await _stopOwners();
      _check(intent, current);
      _state = MeetingAudioPlaybackState.paused;
      _notify();
    });
  }

  Future<void> seek(
    String session,
    int playbackUs, {
    required bool Function() current,
  }) {
    if (playbackUs < 0 || playbackUs > 86400000000) {
      return Future.error(ArgumentError('Invalid playback target'));
    }
    return seekFrame(session, playbackUs * 48000 ~/ 1000000, current: current);
  }

  /// Transcript mappings use exact saved samples, without rounding through
  /// integer microseconds and losing a one-sample tail.
  Future<void> seekFrame(
    String session,
    int playbackFrame, {
    required bool Function() current,
  }) {
    if (playbackFrame < 0 || playbackFrame > 86400 * 48000) {
      return Future.error(ArgumentError('Invalid playback target'));
    }
    final resume =
        sessionId == session && _state == MeetingAudioPlaybackState.playing;
    final intent = _withdraw();
    return _enqueue(intent, current, () async {
      await _stopOwners();
      _check(intent, current);
      if (resume) {
        await _start(session, playbackFrame, intent, current);
        return;
      }
      final source = _source = await openSource(
        session,
        () => _owns(intent) && current(),
      );
      _check(intent, current);
      sessionId = session;
      _totalFrames = source.totalFrames;
      _positionFrame = playbackFrame.clamp(0, _totalFrames);
      await _stopOwners();
      _check(intent, current);
      _state = MeetingAudioPlaybackState.paused;
      _error = '';
      _notify();
    });
  }

  Future<void> _start(
    String session,
    int start,
    int intent,
    bool Function() current,
  ) async {
    await _stopOwners();
    _check(intent, current);
    sessionId = session;
    _state = MeetingAudioPlaybackState.loading;
    _error = '';
    _notify();
    try {
      final source = _source = await openSource(
        session,
        () => _owns(intent) && current(),
      );
      _check(intent, current);
      _totalFrames = source.totalFrames;
      if (_totalFrames < 1 || _totalFrames > 48000 * 86400) {
        throw StateError('Invalid playback duration');
      }
      _baseFrame = start.clamp(0, _totalFrames);
      _positionFrame = _baseFrame;
      _nextFrame = _baseFrame;
      if (_baseFrame == _totalFrames) {
        await _stopOwners();
        _state = MeetingAudioPlaybackState.paused;
        _notify();
        return;
      }
      final output = _output = await openOutput(
        ++_generation,
        () => _owns(intent) && current(),
      );
      _check(intent, current);
      if (output.generation != _generation) {
        throw StateError('Playback generation changed');
      }
      await _decodeWindow(intent);
      _check(intent, current);
      _feed(intent);
      await output.resume();
      _check(intent, current);
      _state = MeetingAudioPlaybackState.playing;
      // From here playback belongs to the service session, not the completed
      // request's cancellation predicate. Explicit controls revoke its intent.
      _timer = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => _tick(intent),
      );
      _notify();
    } catch (_) {
      await _stopOwners();
      rethrow;
    }
  }

  Future<void> _decodeWindow(int intent) async {
    final source = _source!;
    final count = math.min(240000, _totalFrames - _nextFrame);
    if (count <= 0) return;
    final pcm = await source.decode(_nextFrame, count);
    if (!_owns(intent)) return;
    if (pcm.length != count) throw StateError('Playback decode extent changed');
    _pcm = pcm;
    _pcmOffset = 0;
    _nextFrame += count;
  }

  void _feed(int intent) {
    final pcm = _pcm, output = _output;
    if (!_owns(intent) || pcm == null || output == null) return;
    // Bounded work per service turn; native queue capacity is 1.6 seconds.
    for (var pass = 0; pass < 8 && _pcmOffset < pcm.length; pass++) {
      final frames = math.min(4800, pcm.length - _pcmOffset);
      final stereo = Int16List(frames * 2);
      for (var i = 0; i < frames; i++) {
        stereo[i * 2] = stereo[i * 2 + 1] = pcm[_pcmOffset + i];
      }
      final accepted = output.push(stereo, generation: output.generation);
      if (accepted < 0) {
        throw StateError('Playback output no longer accepts this generation');
      }
      if (accepted == 0) break;
      _pcmOffset += accepted;
    }
    if (_pcmOffset == pcm.length) {
      _pcm = null;
      _pcmOffset = 0;
    }
  }

  void _samplePosition() {
    final output = _output;
    if (output == null) return;
    final state = output.snapshot();
    if (state.error != null ||
        state.stopped ||
        state.generation != _generation) {
      throw StateError('Playback output failed');
    }
    _positionFrame = (_baseFrame + state.renderedFrames).clamp(
      _baseFrame,
      _totalFrames,
    );
  }

  void _tick(int intent) {
    if (!_owns(intent) ||
        _state != MeetingAudioPlaybackState.playing ||
        _pumping != null) {
      return;
    }
    var ended = false;
    final work = () async {
      _samplePosition();
      if (_pcm == null && _nextFrame < _totalFrames) {
        await _decodeWindow(intent);
      }
      if (!_owns(intent)) return;
      _feed(intent);
      _samplePosition();
      _notify();
      ended =
          _pcm == null &&
          _nextFrame >= _totalFrames &&
          _positionFrame >= _totalFrames;
    }();
    _pumping = work;
    work
        .then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {
            if (_owns(intent)) {
              _state = MeetingAudioPlaybackState.failed;
              _error = 'Saved audio playback needs attention';
              _notify();
            }
          },
        )
        .whenComplete(() {
          _pumping = null;
          if (!_owns(intent)) return;
          if (ended || _state == MeetingAudioPlaybackState.failed) {
            _timer?.cancel();
            _timer = null;
            final failed = _state == MeetingAudioPlaybackState.failed;
            _stopOwners()
                .then(
                  (_) {
                    if (_owns(intent)) {
                      _state = failed
                          ? MeetingAudioPlaybackState.failed
                          : MeetingAudioPlaybackState.paused;
                      _notify();
                    }
                  },
                  onError: (Object _, StackTrace _) {
                    _poisoned = true;
                    _state = MeetingAudioPlaybackState.failed;
                    _error =
                        'Playback ownership is unconfirmed; restart the service';
                    _notify();
                  },
                )
                .ignore();
          }
        })
        .ignore();
  }

  Future<void>? _stopping;
  Future<void> _stopOwners() => _stopping ??= () async {
    _timer?.cancel();
    _timer = null;
    final source = _source, output = _output, pumping = _pumping;
    try {
      source?.cancel();
    } catch (_) {
      /* Each owner still closes below. */
    }
    final owners = <Future<void>>[
      if (output != null) output.close(),
      if (source != null) source.close(),
      if (pumping != null)
        pumping.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ];
    try {
      await Future.wait(owners);
    } catch (_) {
      _poisoned = true;
      rethrow;
    }
    _source = null;
    _output = null;
    _pcm = null;
    _pcmOffset = 0;
  }().whenComplete(() => _stopping = null);

  Future<void> close() => _closing ??= () async {
    _closed = true;
    _withdraw();
    await _tail;
    await _stopOwners();
    _state = MeetingAudioPlaybackState.idle;
  }();

  /// Trusted service barrier for deletion/workspace handoff. It remains usable
  /// after ordinary cancellation and does not resume capture or transcription.
  Future<void> stop({bool clearSelection = false}) {
    try {
      _samplePosition();
    } catch (_) {
      /* Still stop failed output. */
    }
    _withdraw();
    final work = _tail.then((_) async {
      await _stopOwners();
      _state = MeetingAudioPlaybackState.paused;
      if (clearSelection) {
        sessionId = null;
        _positionFrame = _totalFrames = 0;
        _state = MeetingAudioPlaybackState.idle;
      }
      _notify();
    });
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }
}
