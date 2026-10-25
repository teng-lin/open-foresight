import '../audio_devices.dart';
import '../platform_services.dart' show RuntimeConfiguration;
import '../operation_requests.dart';
import '../operation_registry.dart';
import '../operations.dart';

/// OS enumeration and permission operations execute only in the service. A
/// capability read or enumeration never invokes either permission request.
/// Default adapters use the owning service's [configuration] snapshot.
final class AudioOperations {
  AudioOperations({
    RuntimeConfiguration? configuration,
    Future<List<AudioDevice>> Function()? enumerate,
    Map<String, dynamic> Function()? capabilities,
    Future<Map<String, dynamic>> Function()? requestSystem,
    Future<Map<String, dynamic>> Function()? requestMicrophone,
  }) : enumerate =
           enumerate ?? (() => audioDevices(configuration: configuration)),
       capabilities =
           capabilities ??
           (() => audioCapabilities(configuration: configuration)),
       requestSystem =
           requestSystem ??
           (() => requestSystemAudioPermission(configuration: configuration)),
       requestMicrophone =
           requestMicrophone ??
           (() => requestMicrophonePermission(configuration: configuration));
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
