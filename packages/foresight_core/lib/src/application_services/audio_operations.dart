import '../audio_devices.dart';
import '../operation_requests.dart';
import '../operation_registry.dart';
import '../operations.dart';

/// OS enumeration and permission operations execute only in the service. A
/// capability read or enumeration never invokes either permission request.
final class AudioOperations {
  AudioOperations({
    this.enumerate = audioDevices,
    this.capabilities = audioCapabilities,
    this.requestSystem = requestSystemAudioPermission,
    this.requestMicrophone = requestMicrophonePermission,
  });
  final Future<List<AudioDevice>> Function() enumerate;
  final Map<String, dynamic> Function() capabilities;
  final Future<Map<String, dynamic>> Function() requestSystem,
      requestMicrophone;

  List<OperationHandler> get handlers => [
    TypedOperationHandler<AudioCapabilitiesRequest>(
      Operation.audioCapabilities,
      (request, {current}) async => {
        ...capabilities(),
        if (request.enumerateDevices)
          'devices': [for (final device in await enumerate()) device.toWire()],
      },
    ),
    TypedOperationHandler<AudioRequestSystemRequest>(
      Operation.audioRequestSystem,
      (request, {current}) => requestSystem(),
    ),
    TypedOperationHandler<AudioRequestMicrophoneRequest>(
      Operation.audioRequestMicrophone,
      (request, {current}) => requestMicrophone(),
    ),
  ];
}
