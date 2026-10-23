import '../operation_descriptor.dart';
import '../operation_argument_schema.dart';

const meetingsListDescriptor = OperationDescriptor(
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

const meetingsCreateDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.never,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: true,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("title", ArgumentKind.string),
  ]),
);

const meetingsGetDescriptor = OperationDescriptor(
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
    ArgumentField("id", ArgumentKind.integer),
  ]),
);

const meetingsRetryQuestionDescriptor = OperationDescriptor(
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
    ArgumentField("id", ArgumentKind.integer),
  ]),
);

const meetingsRetryDetectionDescriptor = OperationDescriptor(
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
    ArgumentField("id", ArgumentKind.integer),
  ]),
);

const meetingsLinkAnswerDescriptor = OperationDescriptor(
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
    ArgumentField("id", ArgumentKind.integer),
    ArgumentField("answer", ArgumentKind.integer),
  ]),
);

const meetingsNotesDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.overwrite,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
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
    ArgumentField("body", ArgumentKind.string),
    ArgumentField("last_manual_edit", ArgumentKind.integer, nullable: true),
  ]),
);

const meetingsTranscriptDescriptor = OperationDescriptor(
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
    ArgumentField("id", ArgumentKind.integer),
    ArgumentField("text", ArgumentKind.string),
    ArgumentField("start", ArgumentKind.integer, defaultValue: 0),
    ArgumentField("end", ArgumentKind.integer, defaultValue: 0),
    ArgumentField("source", ArgumentKind.string, defaultValue: 'imported'),
  ]),
);

const meetingsIndexDescriptor = OperationDescriptor(
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

const meetingsGenerateDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.overwrite,
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
    ArgumentField("kind", ArgumentKind.string),
  ]),
);

const meetingsTasksDescriptor = OperationDescriptor(
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
    ArgumentField("id", ArgumentKind.integer),
  ]),
);

const meetingsEditTaskDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.overwrite,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
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
    ArgumentField("task", ArgumentKind.string, nullable: true),
    ArgumentField("owner", ArgumentKind.string, nullable: true),
    ArgumentField("due", ArgumentKind.string, nullable: true),
    ArgumentField(
      "status",
      ArgumentKind.string,
      nullable: true,
      choices: ['open', 'completed', 'cancelled'],
    ),
  ]),
);

const meetingsPrepareDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.overwrite,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
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
    ArgumentField(
      "source_ids",
      ArgumentKind.strings,
      minimumItems: 1,
      maximumItems: 100,
      distinct: true,
    ),
  ]),
);

const meetingsCancelGenerationDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.never,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: false,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: true,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("id", ArgumentKind.integer),
    ArgumentField("kind", ArgumentKind.string, nullable: true),
  ]),
);

const meetingsEnhanceDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.overwrite,
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
    ArgumentField("force_regenerate", ArgumentKind.trueSwitch),
  ]),
);

const meetingsCancelEnhanceDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.never,
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
    ArgumentField("id", ArgumentKind.integer),
    ArgumentField("request_id", ArgumentKind.string, nullable: true),
  ]),
);

const meetingsCancelSummaryDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.never,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: false,
  modelGate: ModelGatePolicy.none,
  notifiesChanges: false,
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

const meetingsStartDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.hostedRecording,
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

const meetingsStopDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.never,
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

const meetingsPauseDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.never,
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
    ArgumentField("id", ArgumentKind.integer, nullable: true),
  ]),
);

const meetingsResumeDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.hostedRecording,
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
    ArgumentField("id", ArgumentKind.integer, nullable: true),
  ]),
);
