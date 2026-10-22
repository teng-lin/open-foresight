import '../operation_descriptor.dart';
import '../operation_argument_schema.dart';

const sourcesListDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: true,
  approval: ApprovalPolicy.never,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: false,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([]),
);

const sourcesGetDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: true,
  approval: ApprovalPolicy.never,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: false,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("id", ArgumentKind.string),
  ]),
);

const sourcesImportDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: true,
  acceptsIdempotencyKey: true,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("id", ArgumentKind.string, nullable: true),
    ArgumentField("title", ArgumentKind.string),
    ArgumentField("text", ArgumentKind.string),
    ArgumentField("mime", ArgumentKind.string, defaultValue: 'text/plain'),
    ArgumentField("provenance", ArgumentKind.string, defaultValue: 'mcp'),
    ArgumentField("modifiedAtMs", ArgumentKind.integer, nullable: true),
    ArgumentField("sourceUri", ArgumentKind.string, nullable: true),
    ArgumentField("locallyEdited", ArgumentKind.trueSwitch),
    ArgumentField("index", ArgumentKind.falseSwitch),
  ]),
);

const sourcesImportUrlDescriptor = OperationDescriptor(
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
    ArgumentField("url", ArgumentKind.string),
    ArgumentField("allow_private_network", ArgumentKind.trueSwitch),
  ]),
);

const sourcesImportDirectoryDescriptor = OperationDescriptor(
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
    ArgumentField("path", ArgumentKind.string),
  ]),
);

const sourcesRefreshDescriptor = OperationDescriptor(
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
    ArgumentField("allow_private_network", ArgumentKind.trueSwitch),
  ]),
);

const sourcesImportFileDescriptor = OperationDescriptor(
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
    ArgumentField("path", ArgumentKind.string),
  ]),
);

const sourcesIndexDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.never,
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
  ]),
);

const sourcesDeleteDescriptor = OperationDescriptor(
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
  ]),
);

const sourcesPauseDescriptor = OperationDescriptor(
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
  arguments: OperationArgumentSchema([]),
);

const sourcesResumeDescriptor = OperationDescriptor(
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
  arguments: OperationArgumentSchema([]),
);

const sourcesSearchDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: true,
  approval: ApprovalPolicy.never,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: false,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("query", ArgumentKind.string),
    ArgumentField(
      "limit",
      ArgumentKind.integer,
      defaultValue: 10,
      minimum: 1,
      maximum: 100,
    ),
  ]),
);
