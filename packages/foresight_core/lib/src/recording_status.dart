import 'desktop_connection.dart';
import 'read_models.dart';
import 'desktop_status.dart';

/// Immutable capture presentation state; owns no recorder or native handle.
final class RecordingSnapshot implements RecordingStatus {
  final Map<String, Object?> snapshot;
  RecordingSnapshot(Map<String, dynamic> snapshot)
    : snapshot = immutableReadMap(snapshot);

  /// Consume the already decoded desktop value without exposing wire maps.
  RecordingSnapshot.fromPresentation(CapturePresentation value)
    : this({
        'finishing': value.finishing,
        'paused': value.paused,
        'samples': value.samples,
        'peaks': value.peaks,
        'volumes': value.volumes,
        if (value.lastAudioMilliseconds != null)
          'last_audio': value.lastAudioMilliseconds,
        'echo_cancellation': {
          'requested': value.echoCancellation.requested,
          'active': value.echoCancellation.active,
          'pending': value.echoCancellation.pending,
          'restart_required': value.echoCancellation.restartRequired,
          'fallback_status': value.echoCancellation.fallbackStatus,
          'fallback_reason': value.echoCancellation.fallbackReason,
          if (value.echoCancellation.supported != null)
            'supported': value.echoCancellation.supported,
        },
      });
  @override
  bool get finishing => snapshot['finishing'] == true;
  @override
  bool get paused => snapshot['paused'] == true;
  @override
  Map<String, dynamic> get echoCancellationState => Map<String, dynamic>.from(
    snapshot['echo_cancellation'] as Map? ??
        {'requested': false, 'active': false},
  );
  @override
  List<int> get sampleCounts =>
      (snapshot['samples'] as List? ?? []).cast<int>();
  @override
  List<double> get peakVolumes => (snapshot['peaks'] as List? ?? [])
      .map((v) => (v as num).toDouble())
      .toList();
  @override
  DateTime get lastAudioActivity => DateTime.fromMillisecondsSinceEpoch(
    snapshot['last_audio'] as int? ?? DateTime.now().millisecondsSinceEpoch,
  );
  @override
  List<double> get currentVolumes => (snapshot['volumes'] as List? ?? [])
      .map((v) => (v as num).toDouble())
      .toList();
  @override
  void dispose() {}
}

/// Legacy core facade spelling; desktop features use RecordingSnapshot.
typedef RemoteRecording = RecordingSnapshot;
