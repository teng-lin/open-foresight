import 'operation_argument_schema.dart';
import 'client_contract.dart';

enum OperationScope { application, service }

enum ApprovalPolicy { never, desktop, webSearch, overwrite }

enum CapabilityPolicy {
  ordinary,
  desktopToken,
  approvalHost,
  hostedRecording,
  profileOwner,
}

enum ModelGatePolicy { none, configuration }

enum ResponseShape { result, answerStream, signInStream }

/// Complete per-operation policy. Admission order and resource ownership stay
/// with the service; these declarations never create a second lifetime ledger.
class OperationDescriptor<Q extends ClientArguments, R> {
  const OperationDescriptor({
    required this.scope,
    required this.readOnly,
    required this.approval,
    required this.capability,
    required this.requiresHelper,
    required this.modelGate,
    required this.notifiesChanges,
    required this.response,
    required this.carriesWorkspaceEpoch,
    required this.acceptsIdempotencyKey,
    required this.stampsAgentActivity,
    required this.leaseBusy,
    required this.createsLease,
    required this.arguments,
    required this.requestEncoder,
    required this.resultDecoder,
  });
  final OperationScope scope;
  final bool readOnly;
  final ApprovalPolicy approval;
  final CapabilityPolicy capability;
  final bool requiresHelper;
  final ModelGatePolicy modelGate;
  final bool notifiesChanges;
  final ResponseShape response;
  final bool carriesWorkspaceEpoch, acceptsIdempotencyKey;
  final bool stampsAgentActivity, leaseBusy, createsLease;
  final OperationArgumentSchema arguments;
  final ClientRequestEncoder<Q> requestEncoder;
  final ClientResultDecoder<R> resultDecoder;

  bool requiresApproval({
    required bool webSearch,
    bool existingContent = true,
  }) => switch (approval) {
    ApprovalPolicy.never => false,
    ApprovalPolicy.desktop => true,
    ApprovalPolicy.webSearch => webSearch,
    ApprovalPolicy.overwrite => existingContent,
  };
}
