import '../operation_descriptor.dart';
import '../client_contract.dart';
import '../client_results.dart';
import '../client_requests/labels.dart';
import '../operation_argument_schema.dart';

const labelsAutoAssignDescriptor = OperationDescriptor(
  resultDecoder: ResultCodec(decodeInteger),
  requestEncoder: OperationInputEncoder<LabelsAutoAssignInput>(),
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("name", ArgumentKind.string),
  ]),
);

const labelsPutDescriptor = OperationDescriptor(
  resultDecoder: ResultCodec(decodeNothing),
  requestEncoder: OperationInputEncoder<LabelsPutInput>(),
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: true,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("id", ArgumentKind.string),
    ArgumentField("name", ArgumentKind.string),
    ArgumentField("source", ArgumentKind.string),
    ArgumentField("color", ArgumentKind.string, nullable: true),
    ArgumentField("rationale", ArgumentKind.string, nullable: true),
  ]),
);

const labelsSetDescriptor = OperationDescriptor(
  resultDecoder: ResultCodec(decodeNothing),
  requestEncoder: OperationInputEncoder<LabelsSetInput>(),
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: true,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("id", ArgumentKind.string),
    ArgumentField("labels", ArgumentKind.strings),
  ]),
);

const labelsClusterDescriptor = OperationDescriptor(
  resultDecoder: ResultCodec(decodeNothing),
  requestEncoder: OperationInputEncoder<LabelsClusterInput>(),
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("name", ArgumentKind.string),
  ]),
);

const labelsDeleteDescriptor = OperationDescriptor(
  resultDecoder: ResultCodec(decodeNothing),
  requestEncoder: OperationInputEncoder<LabelsDeleteInput>(),
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("name", ArgumentKind.string),
  ]),
);
