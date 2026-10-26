import '../audio_devices.dart';
import '../platform_services.dart'
    show
        RuntimeConfiguration,
        currentOwnerRuntimeSnapshot,
        legacyRuntimeSnapshot;
import '../operation_requests.dart';
import '../operation_registry.dart';
import '../operations.dart';

/// OS enumeration and permission operations execute only in the service. A
/// capability read or enumeration never invokes either permission request.
/// Default adapters use a [configuration] snapshot frozen here, else their
/// owner's snapshot ([ownerConfiguration]), else the owner snapshot bound at
/// construction; outside any owner scope they read the boundary per call.
final class AudioOperations {
  AudioOperations({
    RuntimeConfiguration? configuration,
    RuntimeConfiguration Function()? ownerConfiguration,
    Future<List<AudioDevice>> Function()? enumerate,
    Map<String, dynamic> Function()? capabilities,
    Future<Map<String, dynamic>> Function()? requestSystem,
    Future<Map<String, dynamic>> Function()? requestMicrophone,
  }) : this._(
         configuration?.snapshot() ??
             (ownerConfiguration == null ? currentOwnerRuntimeSnapshot : null),
         ownerConfiguration,
         enumerate: enumerate,
         capabilities: capabilities,
         requestSystem: requestSystem,
         requestMicrophone: requestMicrophone,
       );
  AudioOperations._(
    RuntimeConfiguration? configuration,
    RuntimeConfiguration Function()? ownerConfiguration, {
    Future<List<AudioDevice>> Function()? enumerate,
    Map<String, dynamic> Function()? capabilities,
    Future<Map<String, dynamic>> Function()? requestSystem,
    Future<Map<String, dynamic>> Function()? requestMicrophone,
  }) : enumerate =
           enumerate ??
           (() => audioDevices(
             configuration:
                 configuration ??
                 ownerConfiguration?.call() ??
                 legacyRuntimeSnapshot(),
           )),
       capabilities =
           capabilities ??
           (() => audioCapabilities(
             configuration:
                 configuration ??
                 ownerConfiguration?.call() ??
                 legacyRuntimeSnapshot(),
           )),
       requestSystem =
           requestSystem ??
           (() => requestSystemAudioPermission(
             configuration:
                 configuration ??
                 ownerConfiguration?.call() ??
                 legacyRuntimeSnapshot(),
           )),
       requestMicrophone =
           requestMicrophone ??
           (() => requestMicrophonePermission(
             configuration:
                 configuration ??
                 ownerConfiguration?.call() ??
                 legacyRuntimeSnapshot(),
           ));
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
