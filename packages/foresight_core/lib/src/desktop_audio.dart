import 'audio_device.dart';
import 'desktop_connection.dart';
import 'client_command.dart';
import 'client_contract.dart';
import 'client_requests.dart';
import 'operation_descriptors.dart';
import 'rpc_error.dart';

extension DesktopAudioDevices on DesktopConnection {
  /// Enumeration belongs to the service and never requests OS permission.
  Future<List<AudioDevice>> discoverAudioDevices() async {
    final result = await audioCapabilitiesDescriptor.send(
      this,
      const AudioCapabilitiesInput(enumerateDevices: WireField(true)),
    );
    final devices = result.devices.value;
    if (!result.devices.present || devices == null) {
      throw RpcError(
        RpcErrorCode.internal,
        'Invalid audio enumeration response',
        reason: RpcErrorReason.outcomeUnknown,
      );
    }
    return devices;
  }
}
