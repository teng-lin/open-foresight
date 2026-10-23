import '../operation_descriptor.dart';
import '../operation_argument_schema.dart';

const securityAttachDesktopDescriptor = OperationDescriptor(
  scope: OperationScope.service,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.desktopToken,
  requiresHelper: true,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: false,
  leaseBusy: true,
  createsLease: false,
  arguments: OperationArgumentSchema([
    ArgumentField("token", ArgumentKind.string),
    ArgumentField('visible', ArgumentKind.trueSwitch),
  ]),
);

const securityDetachDesktopDescriptor = OperationDescriptor(
  scope: OperationScope.service,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.approvalHost,
  requiresHelper: true,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: false,
  leaseBusy: true,
  createsLease: false,
  arguments: OperationArgumentSchema([]),
);

const securityDesktopVisibilityDescriptor = OperationDescriptor(
  scope: OperationScope.service,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.approvalHost,
  requiresHelper: false,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: false,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: false,
  leaseBusy: false,
  createsLease: false,
  arguments: OperationArgumentSchema([
    ArgumentField('visible', ArgumentKind.trueSwitch),
  ]),
);

const securityDecideDescriptor = OperationDescriptor(
  scope: OperationScope.service,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.approvalHost,
  requiresHelper: true,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: false,
  leaseBusy: true,
  createsLease: false,
  arguments: OperationArgumentSchema([
    ArgumentField("approval_id", ArgumentKind.string),
    ArgumentField("allow", ArgumentKind.trueSwitch),
  ]),
);

const securityAllowImportRootDescriptor = OperationDescriptor(
  scope: OperationScope.service,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.approvalHost,
  requiresHelper: true,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: false,
  leaseBusy: true,
  createsLease: false,
  arguments: OperationArgumentSchema([
    ArgumentField("path", ArgumentKind.string),
  ]),
);
