import '../durable_capture.dart';
import '../audio_models.dart';
import '../persistence/recording_media.dart';
import 'recording_audio_work.dart';
import 'dart:async';
import 'dart:io';

import 'service_runtime_ports.dart';
import '../persistence/capture_queries.dart';
import '../persistence/meeting_queries.dart';
import '../proactive_questions.dart';
import '../recording.dart';
import '../rpc_error.dart';
import '../service_diagnostics.dart';
import '../diagnostics/events.dart';
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
  final RecordingWorkspace domain;
  final GenerationCoordinator generation;
  final ProactiveQuestions proactive;
  final NoteEnhancementCoordinator notes;
  final MeetingIndexer indexer;
  final CaptureActivity capture;
  final MeetingQueries meetings;
  final CaptureQueries queries;
  final void Function() changed, levelsChanged;
  final _diagnostics = captureServiceDiagnosticEmitter();
  void _diagnose(
    DiagnosticEvent event,
    Map<DiagnosticField, Object> Function() fields,
  ) {
    try {
      _diagnostics?.emit(event, fields: fields);
    } catch (_) {
      // Diagnostics cannot change capture cleanup or replace its failure.
    }
  }

  RecordingMedia? _media;
  RecordingAudioWorkPort? _audioWork;
  DurableCapturePlatform? _capturePlatform;
  void configureDurableAudio(
    RecordingMedia media,
    RecordingAudioWorkPort work, {
    DurableCapturePlatform? capturePlatform,
  }) {
    if (recording != null || _stopping != null) {
      throw StateError('Cannot replace media authority during capture');
    }
    _media = media;
    _audioWork = work;
    _capturePlatform = capturePlatform;
  }

  Store get store => domain.store;
  bool get modelBusy => generation.modelBusy;
  bool _closed = false, _controlling = false;
  Future<void>? _closing, _stopping;
  Recording? _recording;
  Recording? get recording => _recording;
  set recording(Recording? value) {
    _recording = value;
    capture.active = value != null && value.lastError.isEmpty;
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
  bool _physicalActive = false;
  String _persistenceState = 'saved';
  String _terminalError = '';
  Map<String, Object?> get state => {
    'meeting_id': recordingMeeting,
    // Active retains session ownership while paused; capture_active alone
    // reports accepted native acquisition and is false through stop/failure.
    'active': recording != null && recording!.lastError.isEmpty,
    'capture_active': recording?.captureActive ?? false,
    'error': recording?.lastError.isNotEmpty == true
        ? recording!.lastError
        : _terminalError.isEmpty
        ? null
        : _terminalError,
    'audio_session_id': recording?.audioSessionId,
    'starting': recording?.starting ?? false,
    'finishing': recording?.finishing ?? false,
    'paused': recording?.paused ?? false,
    'began': recordingBegan?.millisecondsSinceEpoch,
    'elapsed_ms':
        recording?.recordedElapsedMs ??
        (recordingBegan == null
            ? 0
            : (_recordingPausedAt ?? domain.clock.now())
                      .difference(recordingBegan!)
                      .inMilliseconds -
                  _recordingPausedMs),
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
    final media = _media;
    final audioWork = _audioWork;
    if (media == null || audioWork == null) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Durable recording storage is unavailable',
      );
    }
    provisionalTranscript.clear();
    final session = ++_session;
    _unsavedSegments = 0;
    _persistenceState = 'saved';
    _terminalError = '';
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
            unawaited(
              stopRecording(
                cause: DiagnosticCaptureStopReason.transcriptStorageFailure,
              ).catchError((Object _) {}),
            );
          }
        });
      },
    );
    final active = Recording.durable(
      domain.configuration.nativeLibrary,
      (state) {
        if (session != _session ||
            persistence.failed ||
            persistence.pending > 0) {
          return;
        }
        final warning = recording?.lastError ?? '';
        if (warning.isNotEmpty && state != warning) return;
        recordingState = state;
        changed();
      },
      (text, start, end, source) => persistence.add(
        RecordingTranscriptSegment(text, start, end, source, finalText: true),
      ),
      media: media,
      work: audioWork,
      meetingId: id,
      modelRevision: speech.digest,
      now: domain.clock.now,
      createTimer: domain.createTimer,
      platform: _capturePlatform,
      levels: () {
        final owner = recording;
        final acquired = owner?.captureActive ?? false;
        capture.active = owner != null && owner.lastError.isEmpty;
        if (_physicalActive != acquired) {
          _physicalActive = acquired;
          if (acquired && recordingMeeting == id && _stopping == null) {
            queries.setState(id, 'recording');
          }
          changed();
        }
        if (!_closed) levelsChanged();
        if (owner?.lastError.isNotEmpty == true && _stopping == null) {
          scheduleMicrotask(() {
            if (session == _session) {
              stopRecording(
                cause: DiagnosticCaptureStopReason.captureFailure,
              ).ignore();
            }
          });
        }
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
      if (audioWork is RecordingAudioAdmission) {
        await (audioWork as RecordingAudioAdmission).prepareForCapture();
        if (_closed || session != _session || !identical(recording, active)) {
          throw RpcError(RpcErrorCode.cancelled, 'Recording start cancelled');
        }
      }
      await active.start(
        speech.runtime,
        speech.path,
        microphoneTarget:
            domain.configuration['FORESIGHT_MICROPHONE_TARGET'] ??
            store.preference('microphoneTarget', 'auto'),
        playbackTarget:
            domain.configuration['FORESIGHT_PLAYBACK_TARGET'] ??
            store.preference('playbackTarget', 'auto'),
        echoCancellation:
            Platform.isMacOS &&
            store.preference('echoCancellation', 'false') == 'true',
      );
      if (_closed || session != _session || !identical(recording, active)) {
        throw RpcError(RpcErrorCode.cancelled, 'Recording start cancelled');
      }
      started = true;
      proactive.begin(id);
      notes.scheduleLiveTranscript(id);
      recordingBegan = domain.clock.now();
      _recordingPausedAt = null;
      _recordingPausedMs = 0;
      queries.setState(id, active.captureActive ? 'recording' : 'starting');
      _inactivity = Timer.periodic(const Duration(seconds: 5), (_) {
        try {
          final minutes =
              double.tryParse(store.preference('inactivity', '15')) ?? 15;
          if (minutes > 0 &&
              !active.paused &&
              !active.finishing &&
              !active.starting &&
              (active.freshCaptureInactivity ??
                          domain.clock.now().difference(
                            active.lastAudioActivity,
                          ))
                      .inSeconds >=
                  minutes * 60) {
            unawaited(
              stopRecording(
                cause: DiagnosticCaptureStopReason.inactivity,
                reason:
                    'Recording stopped after $minutes minutes without audio.',
              ).catchError((Object _) {}),
            );
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
      final cancelledBeforeAdmission =
          !started &&
          (_closed ||
              _stopping != null ||
              session != _session ||
              !identical(recording, active));
      if (started) {
        try {
          await _beginStop(initialFailure: error, initialStack: stack);
        } catch (_) {
          // Cleanup and its status writes cannot replace the startup failure.
        }
      } else {
        try {
          active.dispose();
          await active.closed;
        } catch (_) {
          // Retain the original start failure.
        } finally {
          if (identical(recording, active) && session == _session) {
            if (!active.hasCaptureOwnership) {
              _releaseRecording();
            } else {
              // A failed startup may already own an earlier source. A failed
              // finish/retire fence cannot release its capture/media authority.
              capture.active = false;
              recordingState = active.lastError;
              _notify();
            }
            if (identical(_persistence, persistence)) _persistence = null;
          }
          persistence.dispose();
        }
      }
      Error.throwWithStackTrace(
        cancelledBeforeAdmission
            ? RpcError(RpcErrorCode.cancelled, 'Recording start cancelled')
            : error,
        stack,
      );
    }
  }

  Future<void> stopRecording({
    String? reason,
    DiagnosticCaptureStopReason cause = DiagnosticCaptureStopReason.user,
  }) => _beginStop(reason: reason, cause: cause);

  Future<void> _beginStop({
    Object? initialFailure,
    StackTrace? initialStack,
    String? reason,
    DiagnosticCaptureStopReason cause =
        DiagnosticCaptureStopReason.controlFailure,
  }) => _stopping ??= _stopRecording(
    initialFailure: initialFailure,
    initialStack: initialStack,
    reason: reason,
    cause: cause,
  ).whenComplete(() => _stopping = null);

  Recording _activeRecording(int? id) {
    final active = recording;
    if (active == null || (id != null && id != recordingMeeting)) {
      throw RpcError(RpcErrorCode.notFound, 'No matching active recording');
    }
    if (active.finishing ||
        active.starting ||
        _stopping != null ||
        _controlling) {
      throw RpcError(RpcErrorCode.busy, 'Transcription is finalizing');
    }
    return active;
  }

  Future<void> pauseRecording([int? id]) async {
    final active = _activeRecording(id);
    _controlling = true;
    try {
      await _controlCapture(active, () async {
        await active.pause();
        if (!identical(recording, active) || _stopping != null) {
          throw RpcError(RpcErrorCode.cancelled, 'Recording pause cancelled');
        }
        _recordingPausedAt ??= domain.clock.now();
        provisionalTranscript.clear();
        proactive.clearInterim(recordingMeeting!);
        queries.setState(recordingMeeting!, 'paused');
        changed();
      });
    } finally {
      _controlling = false;
    }
  }

  Future<void> resumeRecording([int? id]) async {
    final active = _activeRecording(id);
    if (!active.paused) throw StateError('Recording is not paused');
    _controlling = true;
    try {
      try {
        await active.resume();
      } catch (error, stack) {
        if (identical(recording, active) &&
            (!active.paused || active.hasCaptureOwnership)) {
          try {
            await _beginStop(initialFailure: error, initialStack: stack);
          } catch (_) {}
        }
        Error.throwWithStackTrace(error, stack);
      }
      await _controlCapture(active, () {
        if (!identical(recording, active) || _stopping != null) {
          throw RpcError(RpcErrorCode.cancelled, 'Recording resume cancelled');
        }
        if (_recordingPausedAt != null) {
          _recordingPausedMs += domain.clock
              .now()
              .difference(_recordingPausedAt!)
              .inMilliseconds;
          _recordingPausedAt = null;
        }
        queries.setState(
          recordingMeeting!,
          active.captureActive ? 'recording' : 'starting',
        );
        changed();
      });
    } finally {
      _controlling = false;
    }
  }

  Future<void> _controlCapture(
    Recording owner,
    FutureOr<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error, stack) {
      if (identical(recording, owner)) {
        try {
          await _beginStop(initialFailure: error, initialStack: stack);
        } catch (_) {}
      }
      Error.throwWithStackTrace(error, stack);
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
    final error = recording?.lastError ?? '';
    if (error.isNotEmpty) _terminalError = error;
    recording = null;
    _physicalActive = false;
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
    String? reason,
    required DiagnosticCaptureStopReason cause,
  }) async {
    final active = recording;
    final id = recordingMeeting;
    if (active == null || id == null) return;
    final started = _diagnostics?.clockMicros();
    _diagnose(
      DiagnosticEvent.captureStopRequested,
      () => {
        DiagnosticField.reason: cause,
        DiagnosticField.active: active.captureActive,
      },
    );
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
        recordingState = active.durable
            ? active.lastError
            : 'Transcript retained after speech failure: $error';
      }
      // stop() has joined all owned speech producers; no more segments arrive.
      if (active.durable) {
        recordingState = active.lastError.isNotEmpty
            ? active.lastError
            : 'Audio saved · transcription continues in the background';
      } else if (persistence != null) {
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
      try {
        await active.closed;
      } catch (error, stack) {
        failure ??= speechFailure ?? error;
        failureStack ??= speechStack ?? stack;
      }
      _unsavedSegments = persistence?.pending ?? 0;
      final interrupted =
          failure != null ||
          speechFailure != null ||
          active.lastError.isNotEmpty;
      final status = interrupted
          ? 'interrupted'
          : !active.durable && recordingState.startsWith('No speech')
          ? 'empty'
          : 'completed';
      // A failed final write must not retain capture or wait behind indexing.
      if (!active.hasCaptureOwnership) {
        _releaseRecording();
      } else {
        // A failed native fence is not permission to forget/reuse its owner.
        // Keep the object and media capability reachable until process recovery.
        capture.active = false;
      }
      attempt(() => proactive.clearInterim(id));
      attempt(() => queries.setState(id, status));
      persistence?.dispose();
      _persistence = null;
      if (failure != null && active.durable) {
        _persistenceState = 'failed';
        recordingState = active.lastError.isNotEmpty
            ? active.lastError
            : 'Capture stopped; audio retained but recording metadata needs recovery.';
      } else if (failure != null) {
        _persistenceState = 'failed';
        recordingState = _unsavedSegments > 0
            ? 'Capture interrupted: transcript storage unavailable. '
                  'Some speech was not saved; committed transcript retained.'
            : 'Capture stopped; meeting status could not be saved. '
                  'Committed transcript retained.';
      }
      if (!interrupted && failure == null && reason != null) {
        recordingState = '$reason $recordingState';
      }
      _terminalError = interrupted || failure != null ? recordingState : '';
      _notify();
      _trackIndex(id, session, finalIndex: true);
      _diagnose(
        DiagnosticEvent.captureStopped,
        () => {
          DiagnosticField.reason: cause,
          DiagnosticField.outcome: interrupted || failure != null
              ? DiagnosticOutcome.failed
              : DiagnosticOutcome.completed,
          DiagnosticField.active: active.hasCaptureOwnership,
          DiagnosticField.queued: _unsavedSegments.clamp(0, 0x7fffffff),
          if (started != null)
            DiagnosticField.durationUs:
                ((_diagnostics?.clockMicros() ?? started) - started).clamp(
                  0,
                  0x7fffffff,
                ),
        },
      );
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure!, failureStack ?? StackTrace.current);
    }
  }

  /// The background scheduler invokes this only after its transcript/index
  /// transaction commits. No speech worker status mutates capture warnings.
  void audioTranscriptCommitted(AudioResultCommit result) {
    if (_closed || !result.newlyCommitted) return;
    proactive.notify(result.meetingId);
    notes.scheduleLiveTranscript(result.meetingId);
    notes.scheduleEnhancement(result.meetingId);
    _trackIndex(
      result.meetingId,
      recordingMeeting == result.meetingId ? _session : -1,
      finalIndex: recordingMeeting != result.meetingId,
    );
    changed();
  }

  void stopScheduling() {
    _closed = true;
    _liveIndex?.cancel();
    _inactivity?.cancel();
  }

  Future<void> close() => _closing ??= Future.sync(() async {
    stopScheduling();
    try {
      await stopRecording(
        cause: DiagnosticCaptureStopReason.applicationClosing,
      );
    } finally {
      await Future.wait(_finalIndexes.toList());
    }
  });
}
