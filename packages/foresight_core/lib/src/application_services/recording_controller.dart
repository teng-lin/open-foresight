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
    if (recording != null) {
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
    final active = Recording(
      runtimeConfiguration.nativeLibrary,
      (state) {
        recordingState = state;
        changed();
      },
      (text, start, end, source) {
        store.transcript(
          id,
          text,
          true,
          start,
          end,
          '$source; captured-sample timeline (gaps excluded)',
        );
        provisionalTranscript.remove(source);
        proactive.clearInterim(id, source);
        proactive.notify(id);
        notes.scheduleLiveTranscript(id);
        notes.scheduleEnhancement(id);
        _liveIndex?.cancel();
        _liveIndex = domain.createTimer(
          const Duration(seconds: 1),
          () => unawaited(
            indexer.indexMeeting(id).catchError((Object e) {
              recordingState = 'Live indexing: $e';
              changed();
            }),
          ),
        );
        changed();
      },
      levels: () {
        if (!_closed) levelsChanged();
      },
      provisional: (text, start, end, source) {
        provisionalTranscript[source] = text;
        proactive.updateInterim(id, source, text);
        changed();
      },
      interruption: (event) {
        store.transcript(
          id,
          'Capture interruption: ${event['reason']}; ${event['discarded_bytes']} residual bytes discarded. Captured-sample transcript timing excludes the gap.',
          false,
          0,
          0,
          '${event['source']}-capture-interruption',
        );
        queries.setState(id, 'interrupted');
        changed();
      },
    );
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
    } catch (_) {
      active.dispose();
      rethrow;
    }
    recording = active;
    proactive.begin(id);
    recordingMeeting = id;
    notes.scheduleLiveTranscript(id);
    recordingBegan = domain.clock.now();
    _recordingPausedAt = null;
    _recordingPausedMs = 0;
    queries.setState(id, 'recording');
    _inactivity = Timer.periodic(const Duration(seconds: 5), (_) {
      final minutes =
          double.tryParse(store.preference('inactivity', '15')) ?? 15;
      if (minutes > 0 &&
          !active.paused &&
          !active.finishing &&
          domain.clock.now().difference(active.lastAudioActivity).inSeconds >=
              minutes * 60) {
        unawaited(
          stopRecording().catchError((Object e) {
            recordingState = e.toString();
            changed();
          }),
        );
      }
    });
    changed();
  }

  Future<void> stopRecording() =>
      _stopping ??= _stopRecording().whenComplete(() => _stopping = null);

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
    _activeRecording(id).pause();
    _recordingPausedAt ??= domain.clock.now();
    provisionalTranscript.clear();
    proactive.clearInterim(recordingMeeting!);
    queries.setState(recordingMeeting!, 'paused');
    changed();
  }

  void resumeRecording([int? id]) {
    _activeRecording(id).resume();
    if (_recordingPausedAt != null) {
      _recordingPausedMs += domain.clock
          .now()
          .difference(_recordingPausedAt!)
          .inMilliseconds;
      _recordingPausedAt = null;
    }
    queries.setState(recordingMeeting!, 'recording');
    changed();
  }

  Future<void> _stopRecording() async {
    final active = recording;
    final id = recordingMeeting;
    if (active == null || id == null) return;
    _liveIndex?.cancel();
    _inactivity?.cancel();
    var status = 'interrupted';
    Object? failure;
    queries.setState(id, 'transcribing');
    changed();
    try {
      try {
        await active.stop();
      } catch (error) {
        failure = error;
        active.dispose();
        recordingState = 'Transcript retained after speech failure: $error';
      }
      // Already committed segments remain useful even if a later segment or
      // shutdown failed. Index them before publishing the recoverable state.
      await indexer.indexMeeting(id);
      status = failure != null || active.lastError.isNotEmpty
          ? 'interrupted'
          : recordingState.startsWith('No speech')
          ? 'empty'
          : 'completed';
    } finally {
      recording = null;
      recordingMeeting = null;
      recordingBegan = null;
      _recordingPausedAt = null;
      _recordingPausedMs = 0;
      provisionalTranscript.clear();
      proactive.clearInterim(id);
      queries.setState(id, status);
      changed();
    }
  }

  void stopScheduling() {
    _closed = true;
    _liveIndex?.cancel();
    _inactivity?.cancel();
  }

  Future<void> close() => _closing ??= Future.sync(() async {
    stopScheduling();
    await stopRecording();
  });
}
