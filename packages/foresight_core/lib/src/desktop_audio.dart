import 'audio_device.dart';
import 'desktop_connection.dart';
import 'operations.dart';

extension DesktopAudioDevices on DesktopConnection {
  /// Enumeration belongs to the service and never requests OS permission.
  Future<List<AudioDevice>> discoverAudioDevices() async {
    final result =
        await command(Operation.audioCapabilities, {'enumerate_devices': true})
            as Map;
    return List.unmodifiable(
      (result['devices'] as List).map(
        (value) =>
            AudioDevice.fromWire(Map<String, Object?>.from(value as Map)),
      ),
    );
  }
}
