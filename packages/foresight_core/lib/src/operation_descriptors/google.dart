import '../operation_descriptor.dart';
import '../operation_argument_schema.dart';

const googleStatusDescriptor = OperationDescriptor(
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

const googleConfigureDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("provider", ArgumentKind.string, nullable: true),
    ArgumentField("path", ArgumentKind.string, nullable: true),
  ]),
);

const googleCompleteSignInDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
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
    ArgumentField("manual", ArgumentKind.trueSwitch),
  ]),
);

const googleCancelSignInDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
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

const googleDisconnectDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
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

const googleSwitchAccountDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
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

const googleSignOutAccountDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
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

const googleDriveFilesDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: true,
  approval: ApprovalPolicy.desktop,
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
    ArgumentField("parent", ArgumentKind.string, nullable: true),
    ArgumentField("query", ArgumentKind.string, defaultValue: ''),
    ArgumentField("modifiedAfter", ArgumentKind.dateTime, nullable: true),
  ]),
);

const googleImportFileDescriptor = OperationDescriptor(
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
    ArgumentField("id", ArgumentKind.string),
  ]),
);

const googleImportFolderDescriptor = OperationDescriptor(
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
    ArgumentField("id", ArgumentKind.string),
  ]),
);

const googleImportYearDescriptor = OperationDescriptor(
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

const googleRefreshDescriptor = OperationDescriptor(
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

const googleCalendarDescriptor = OperationDescriptor(
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

const googleAttachmentsDescriptor = OperationDescriptor(
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
    ArgumentField("id", ArgumentKind.integer),
  ]),
);

const googleSignInDescriptor = OperationDescriptor(
  scope: OperationScope.service,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.signInStream,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([]),
);

const googleAddAccountDescriptor = OperationDescriptor(
  scope: OperationScope.service,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.signInStream,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([]),
);
