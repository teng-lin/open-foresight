import 'desktop_connection.dart';
import 'desktop_read_models.dart';

/// Immutable capture presentation state; owns no recorder or native handle.
final class RecordingSnapshot implements RecordingStatus {
  final Map<String, Object?> snapshot;
  RecordingSnapshot(Map<String, dynamic> snapshot)
    : snapshot = immutableReadMap(snapshot);
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
