import 'helper.dart';
import 'operation_requests.dart';
import 'platform_services.dart';
import 'rpc_error.dart';
import 'dart:io';

/// Idle-stop admission only: the service owns the actual close and final reply.
class ServiceIdleShutdownGuard {
  ServiceIdleShutdownGuard({
    required this.helper,
    required this.recording,
    required this.operationsBusy,
    required this.backgroundBusy,
    RuntimeConfiguration? configuration,
  }) : _configuration =
           configuration?.snapshot() ?? currentOwnerRuntimeSnapshot;

  /// An explicit or bound owner snapshot is fixed at construction. Outside any
  /// owner scope this is a legacy direct construction: each access returns a
  /// fresh immutable snapshot of the boundary, as it read it before injection.
  RuntimeConfiguration get configuration =>
      _configuration ?? legacyRuntimeSnapshot();
  final RuntimeConfiguration? _configuration;
  final Helper helper;
  final bool Function() recording, operationsBusy, backgroundBusy;
  void validateOwner(ServiceStopIfIdleRequest request) {
    if ((request.expectedPid != null && request.expectedPid != pid) ||
        (request.installationRoot != null &&
            request.installationRoot != configuration.installationRoot) ||
        (request.runtimeRevision != null &&
            request.runtimeRevision !=
                configuration['FORESIGHT_RUNTIME_REVISION'])) {
      throw RpcError(
        RpcErrorCode.cancelled,
        'Application service ownership changed before idle shutdown; retry without replacing the app.',
      );
    }
  }

  void checkBusy() {
    if (recording()) {
      throw RpcError(
        RpcErrorCode.busy,
        'Recording is active or finalizing. Stop recording and wait for the final transcript before upgrading.',
      );
    }
    if (operationsBusy()) {
      throw RpcError(
        RpcErrorCode.busy,
        'Application operations are in progress. Retry the upgrade after they finish.',
      );
    }
    if (backgroundBusy()) {
      throw RpcError(
        RpcErrorCode.busy,
        'Background model work is in progress. Retry the upgrade after it finishes.',
      );
    }
  }

  Future<AdoptedIdentity>? inspectHelper() {
    if (helper.starting) {
      throw RpcError(
        RpcErrorCode.busy,
        'The helper is still starting. Retry the upgrade after it is ready.',
      );
    }
    if (helper.adopted || (helper.snapshot != null && helper.process == null)) {
      return helper.verifyAdoptedIdentity();
    }
    return null;
  }

  void requireVerified(AdoptedIdentity identity) {
    if (identity == AdoptedIdentity.unknown) {
      throw RpcError(
        RpcErrorCode.busy,
        'Helper shutdown could not be verified. The application was not cleared for upgrade.',
      );
    }
  }
}
