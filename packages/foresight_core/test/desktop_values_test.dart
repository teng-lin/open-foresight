import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:test/test.dart';

void main() {
  test(
    'runtime presentation snapshot excludes credentials and profile identity',
    () {
      installServiceWorkerEnvironment({
        'FORESIGHT_NATIVE': '/fixture/libnative.so',
        'FORESIGHT_LITERT_RUNNER': '/fixture/runner',
        'FORESIGHT_DATA': '/private/profile',
        'FORESIGHT_WEB_CONTENT_API_KEY': 'private-key',
      });
      final snapshot = desktopRuntimeSettings;
      expect(snapshot.nativeLibrary, '/fixture/libnative.so');
      expect(snapshot['FORESIGHT_LITERT_RUNNER'], '/fixture/runner');
      expect(snapshot['FORESIGHT_DATA'], isNull);
      expect(snapshot['FORESIGHT_WEB_CONTENT_API_KEY'], isNull);
      expect(snapshot.webContentAvailable, isTrue);
      runtimeConfiguration.environment['FORESIGHT_LITERT_RUNNER'] = '/replaced';
      expect(snapshot['FORESIGHT_LITERT_RUNNER'], '/fixture/runner');
    },
  );

  test('recording presentation does not retain mutable event payloads', () {
    final samples = [1, 2];
    final echo = <String, dynamic>{'active': true};
    final event = <String, dynamic>{
      'samples': samples,
      'echo_cancellation': echo,
      'last_audio': 42,
    };
    final snapshot = RecordingSnapshot(event);
    samples[0] = 90;
    echo['active'] = false;
    event['last_audio'] = 100;
    expect(snapshot.sampleCounts, [1, 2]);
    expect(snapshot.echoCancellationState['active'], isTrue);
    expect(snapshot.lastAudioActivity.millisecondsSinceEpoch, 42);
    expect(() => snapshot.sampleCounts[0] = 99, throwsUnsupportedError);
  });
  test(
    'recording snapshot accepts typed capture without retaining mutable lists',
    () {
      final samples = [4, 0];
      final capture = CapturePresentation.fromWire({
        'finishing': true,
        'paused': true,
        'samples': samples,
        'peaks': [0.5, 0],
        'volumes': [0.2, 0],
        'last_audio': 42,
        'echo_cancellation': {
          'requested': true,
          'active': true,
          'fallback_reason': 'fixture',
        },
      });
      final snapshot = RecordingSnapshot.fromPresentation(capture);
      samples[0] = 90;
      expect(snapshot.finishing, isTrue);
      expect(snapshot.paused, isTrue);
      expect(snapshot.sampleCounts, [4, 0]);
      expect(snapshot.peakVolumes, [0.5, 0.0]);
      expect(snapshot.currentVolumes, [0.2, 0.0]);
      expect(snapshot.lastAudioActivity.millisecondsSinceEpoch, 42);
      expect(snapshot.echoCancellationState['fallback_reason'], 'fixture');
      expect(() => snapshot.sampleCounts[0] = 90, throwsUnsupportedError);
    },
  );
}
