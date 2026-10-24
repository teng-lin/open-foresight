import 'dart:async';
import 'dart:io';

import '../domain.dart';
import '../persistence/capture_queries.dart';
import '../persistence/meeting_queries.dart';
import '../platform_services.dart';
import '../proactive_questions.dart';
import '../recording.dart';
import '../rpc_error.dart';
import '../store.dart';
import 'capture_activity.dart';
import 'generation_coordinator.dart';
import 'meeting_indexer.dart';
import 'note_enhancement_coordinator.dart';
import 'recording_transcript_persistence.dart';

/// Sole capture process, timer and pause/finalization owner. Notes and indexing
/// receive narrow notifications; capture finishing retains its handle until done.
final class RecordingController {
  RecordingController({
    required this.domain,
    required this.generation,
    required this.proactive,
    required this.notes,
    required this.indexer,
    required this.capture,
    required this.meetings,
    required this.changed,
    required this.levelsChanged,
  }) : queries = CaptureQueries(domain.store, meetings);
  final Domain domain;
  final GenerationCoordinator generation;
  final ProactiveQuestions proactive;
  final NoteEnhancementCoordinator notes;
  final MeetingIndexer indexer;
  final CaptureActivity capture;
  final MeetingQueries meetings;
  final CaptureQueries queries;
  final void Function() changed, levelsChanged;
  Store get store => domain.store;
  bool get modelBusy => generation.modelBusy;
  bool _closed = false;
  Future<void>? _closing, _stopping;
  Recording? _recording;
  Recording? get recording => _recording;
  set recording(Recording? value) {
    _recording = value;
    capture.active = value != null;
  }

  int? get recordingMeeting => capture.meeting;
  set recordingMeeting(int? value) => capture.meeting = value;
  DateTime? recordingBegan;
  DateTime? _recordingPausedAt;
  int _recordingPausedMs = 0;
  String get recordingState => capture.state;
  set recordingState(String value) => capture.state = value;
  final provisionalTranscript = <String, String>{};
  Timer? _liveIndex, _inactivity;
  RecordingTranscriptPersistence? _persistence;
  final _finalIndexes = <Future<void>>{};
  var _session = 0, _unsavedSegments = 0;
  String _persistenceState = 'saved';
  Map<String, Object?> get state => {
    'meeting_id': recordingMeeting,
    'active': recording != null,
    'finishing': recording?.finishing ?? false,
    'paused': recording?.paused ?? false,
    'began': recordingBegan?.millisecondsSinceEpoch,
    'elapsed_ms': recordingBegan == null
        ? 0
        : (_recordingPausedAt ?? domain.clock.now())
                  .difference(recordingBegan!)
                  .inMilliseconds -
              _recordingPausedMs,
    'state': recordingState,
    'transcript_persistence': _persistenceState,
    'unsaved_segments': _persistence?.pending ?? _unsavedSegments,
    'samples': recording?.sampleCounts ?? <int>[],
    'peaks': recording?.peakVolumes ?? <double>[],
    'last_audio': recording?.lastAudioActivity.millisecondsSinceEpoch,
    'provisional': Map.of(provisionalTranscript),
    'volumes': recording?.currentVolumes ?? <double>[],
    'proactive': proactive.state,
    'echo_cancellation':
        recording?.echoCancellationState ??
        {
          'requested': store.preference('echoCancellation', 'false') == 'true',
          'active': false,
        },
  };

  Future<void> startRecording(int id) async {
    if (_closed) throw RpcError(RpcErrorCode.unavailable, 'Application closed');
    if (modelBusy) {
      throw RpcError(RpcErrorCode.busy, 'Model configuration is busy');
    }
    queries.requireMeeting(id);
    if (recording != null || _stopping != null) {
      throw RpcError(RpcErrorCode.busy, 'A meeting is already recording');
    }
    final speech = store.sourceQueries.model('speech');
    if (speech == null) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Register speech model and whisper.cpp runner first',
      );
    }
    provisionalTranscript.clear();
    final session = ++_session;
    _unsavedSegments = 0;
    _persistenceState = 'saved';
    final persistence = _persistence = RecordingTranscriptPersistence(
      store: store,
      meeting: id,
      createTimer: domain.createTimer,
      committed: (segment) {
        if (session != _session) return;
        final recovered = _persistenceState == 'retrying';
        _persistenceState = 'saved';
        if (recovered) {
          recordingState = recording?.paused == true
              ? 'Transcription paused'
              : 'Listening · live transcription';
        }
        if (!segment.finalText) {
          queries.setState(id, 'interrupted');
          changed();
          return;
        }
        provisionalTranscript.remove(segment.source);
        proactive.clearInterim(id, segment.source);
        proactive.notify(id);
        notes.scheduleLiveTranscript(id);
        notes.scheduleEnhancement(id);
        if (_stopping == null && !_closed) {
          _liveIndex?.cancel();
          _liveIndex = domain.createTimer(
            const Duration(seconds: 1),
            () => _trackIndex(id, session, finalIndex: false),
          );
        }
        changed();
      },
      retrying: () {
        _persistenceState = 'retrying';
        recordingState =
            'Transcript storage unavailable; retrying transcript save. '
            'Stop to finish capture safely.';
        _notify();
      },
      exhausted: () {
        _persistenceState = 'failed';
        recordingState =
            'Capture interrupted: transcript storage unavailable. '
            'Some speech was not saved; committed transcript retained.';
        _notify();
        // Finish the callback before stopping its own speech producer.
        scheduleMicrotask(() {
          if (session == _session && recording != null) {
            unawaited(stopRecording().catchError((Object _) {}));
          }
        });
      },
    );
    final active = Recording(
      runtimeConfiguration.nativeLibrary,
      (state) {
        if (session != _session ||
            persistence.failed ||
            persistence.pending > 0) {
          return;
        }
        recordingState = state;
        changed();
      },
      (text, start, end, source) => persistence.add(
        RecordingTranscriptSegment(text, start, end, source, finalText: true),
      ),
      levels: () {
        if (!_closed) levelsChanged();
      },
      provisional: (text, start, end, source) {
        provisionalTranscript[source] = text;
        proactive.updateInterim(id, source, text);
        changed();
      },
      interruption: (event) => persistence.add(
        RecordingTranscriptSegment(
          'Capture interruption: ${event['reason']}; ${event['discarded_bytes']} residual bytes discarded. Captured-sample transcript timing excludes the gap.',
          0,
          0,
          '${event['source']}-capture-interruption',
          finalText: false,
        ),
      ),
    );
    recording = active;
    recordingMeeting = id;
    var started = false;
    try {
      active.start(
        speech.runtime,
        speech.path,
        microphoneTarget:
            runtimeConfiguration['FORESIGHT_MICROPHONE_TARGET'] ??
            store.preference('microphoneTarget', 'auto'),
        playbackTarget:
            runtimeConfiguration['FORESIGHT_PLAYBACK_TARGET'] ??
            store.preference('playbackTarget', 'auto'),
        echoCancellation:
            Platform.isMacOS &&
            store.preference('echoCancellation', 'false') == 'true',
      );
      started = true;
      proactive.begin(id);
      notes.scheduleLiveTranscript(id);
      recordingBegan = domain.clock.now();
      _recordingPausedAt = null;
      _recordingPausedMs = 0;
      queries.setState(id, 'recording');
      _inactivity = Timer.periodic(const Duration(seconds: 5), (_) {
        try {
          final minutes =
              double.tryParse(store.preference('inactivity', '15')) ?? 15;
          if (minutes > 0 &&
              !active.paused &&
              !active.finishing &&
              domain.clock
                      .now()
                      .difference(active.lastAudioActivity)
                      .inSeconds >=
                  minutes * 60) {
            unawaited(stopRecording().catchError((Object _) {}));
          }
        } catch (error, stack) {
          unawaited(
            _beginStop(
              initialFailure: error,
              initialStack: stack,
            ).catchError((Object _) {}),
          );
        }
      });
      changed();
    } catch (error, stack) {
      if (started) {
        try {
          await _beginStop(initialFailure: error, initialStack: stack);
        } catch (_) {
          // Cleanup and its status writes cannot replace the startup failure.
        }
      } else {
        try {
          active.dispose();
        } catch (_) {
          // Retain the original start failure.
        } finally {
          _releaseRecording();
          persistence.dispose();
          _persistence = null;
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> stopRecording() => _beginStop();

  Future<void> _beginStop({Object? initialFailure, StackTrace? initialStack}) =>
      _stopping ??= _stopRecording(
        initialFailure: initialFailure,
        initialStack: initialStack,
      ).whenComplete(() => _stopping = null);

  Recording _activeRecording(int? id) {
    final active = recording;
    if (active == null || (id != null && id != recordingMeeting)) {
      throw RpcError(RpcErrorCode.notFound, 'No matching active recording');
    }
    if (active.finishing || _stopping != null) {
      throw RpcError(RpcErrorCode.busy, 'Transcription is finalizing');
    }
    return active;
  }

  void pauseRecording([int? id]) {
    final active = _activeRecording(id);
    _controlCapture(() {
      active.pause();
      _recordingPausedAt ??= domain.clock.now();
      provisionalTranscript.clear();
      proactive.clearInterim(recordingMeeting!);
      queries.setState(recordingMeeting!, 'paused');
      changed();
    });
  }

  void resumeRecording([int? id]) {
    final active = _activeRecording(id);
    if (!active.paused) throw StateError('Recording is not paused');
    try {
      active.resume();
    } catch (error, stack) {
      // A refused route already releases partial acquisition and stays paused.
      // A failed observer after resuming requires full capture teardown.
      if (!active.paused || active.captures.isNotEmpty) {
        unawaited(
          _beginStop(
            initialFailure: error,
            initialStack: stack,
          ).catchError((Object _) {}),
        );
      }
      rethrow;
    }
    _controlCapture(() {
      if (_recordingPausedAt != null) {
        _recordingPausedMs += domain.clock
            .now()
            .difference(_recordingPausedAt!)
            .inMilliseconds;
        _recordingPausedAt = null;
      }
      queries.setState(recordingMeeting!, 'recording');
      changed();
    });
  }

  void _controlCapture(void Function() operation) {
    try {
      operation();
    } catch (error, stack) {
      // Admission checks precede this boundary. A failed write or observer after
      // admission must not leave resumed devices live.
      unawaited(
        _beginStop(
          initialFailure: error,
          initialStack: stack,
        ).catchError((Object _) {}),
      );
      rethrow;
    }
  }

  void _notify() {
    try {
      changed();
    } catch (_) {
      // A presentation callback is never allowed to prevent capture cleanup.
    }
  }

  void _releaseRecording() {
    recording = null;
    recordingMeeting = null;
    recordingBegan = null;
    _recordingPausedAt = null;
    _recordingPausedMs = 0;
    provisionalTranscript.clear();
  }

  void _trackIndex(int id, int session, {required bool finalIndex}) {
    final workspace = domain.workspaceGeneration;
    late final Future<void> work;
    work =
        Future<void>.sync(
              () => finalIndex
                  ? indexer.scheduleFinalIndex(id)
                  : indexer.indexMeeting(id),
            )
            .catchError((Object _) {
              // The persisted source/intent remains recoverable. Never overwrite a
              // newer recording's status when the old meeting finally settles.
              if (session == _session &&
                  recording == null &&
                  workspace == domain.workspaceGeneration &&
                  !domain.closed) {
                if (_persistenceState != 'failed') {
                  recordingState =
                      'Transcript retained; meeting indexing needs retry.';
                }
                _notify();
              }
            })
            .whenComplete(() => _finalIndexes.remove(work));
    _finalIndexes.add(work);
  }

  Future<void> _stopRecording({
    Object? initialFailure,
    StackTrace? initialStack,
  }) async {
    final active = recording;
    final id = recordingMeeting;
    if (active == null || id == null) return;
    final persistence = _persistence;
    final session = _session;
    _liveIndex?.cancel();
    _inactivity?.cancel();
    Object? failure = initialFailure;
    StackTrace? failureStack = initialStack;
    Object? speechFailure;
    StackTrace? speechStack;
    void attempt(void Function() operation) {
      try {
        operation();
      } catch (error, stack) {
        failure ??= speechFailure ?? error;
        failureStack ??= speechStack ?? stack;
      }
    }

    // Persistence is advisory to physical capture ownership: even the very
    // first status write is inside the cleanup boundary.
    attempt(() => queries.setState(id, 'transcribing'));
    _notify();
    try {
      try {
        await active.stop();
      } catch (error, stack) {
        speechFailure = error;
        speechStack = stack;
        recordingState = 'Transcript retained after speech failure: $error';
      }
      // stop() has joined all owned speech producers; no more segments arrive.
      if (persistence != null) {
        await persistence.settled;
        if (persistence.failed) {
          failure ??= persistence.failure;
          failureStack ??= persistence.failureStack;
        } else if (speechFailure == null && active.lastError.isEmpty) {
          recordingState = persistence.finalCommitted == 0
              ? 'No speech detected. Check microphone mute and playback.'
              : 'Transcript saved';
        }
      }
    } finally {
      attempt(active.dispose);
      _unsavedSegments = persistence?.pending ?? 0;
      final interrupted =
          failure != null ||
          speechFailure != null ||
          active.lastError.isNotEmpty;
      final status = interrupted
          ? 'interrupted'
          : recordingState.startsWith('No speech')
          ? 'empty'
          : 'completed';
      // A failed final write must not retain capture or wait behind indexing.
      _releaseRecording();
      attempt(() => proactive.clearInterim(id));
      attempt(() => queries.setState(id, status));
      persistence?.dispose();
      _persistence = null;
      if (failure != null) {
        _persistenceState = 'failed';
        recordingState = _unsavedSegments > 0
            ? 'Capture interrupted: transcript storage unavailable. '
                  'Some speech was not saved; committed transcript retained.'
            : 'Capture stopped; meeting status could not be saved. '
                  'Committed transcript retained.';
      }
      _notify();
      _trackIndex(id, session, finalIndex: true);
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure!, failureStack ?? StackTrace.current);
    }
  }

  void stopScheduling() {
    _closed = true;
    _liveIndex?.cancel();
    _inactivity?.cancel();
  }

  Future<void> close() => _closing ??= Future.sync(() async {
    stopScheduling();
    try {
      await stopRecording();
    } finally {
      await Future.wait(_finalIndexes.toList());
    }
  });
}
