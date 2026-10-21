/// Shared capture facts, with no recording/native handle. The recording owner
/// writes these; Notes uses them to select live grounding and report failures.
final class CaptureActivity {
  int? meeting;
  bool active = false;
  String state = '';
}
