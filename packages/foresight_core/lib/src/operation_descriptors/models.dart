import '../operation_descriptor.dart';
import '../operation_argument_schema.dart';

const modelsDownloadAssetDescriptor = OperationDescriptor(
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
    ArgumentField(
      'kind',
      ArgumentKind.string,
      choices: ['generation', 'embedding', 'speech'],
    ),
    ArgumentField(
      'digest',
      ArgumentKind.string,
      minimumLength: 64,
      maximumLength: 64,
    ),
  ]),
);

const modelsInspectAssetDescriptor = OperationDescriptor(
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
    ArgumentField(
      'kind',
      ArgumentKind.string,
      choices: ['generation', 'embedding', 'speech'],
    ),
    ArgumentField(
      'digest',
      ArgumentKind.string,
      minimumLength: 64,
      maximumLength: 64,
    ),
  ]),
);

const modelsCancelQueryAcquisitionDescriptor = OperationDescriptor(
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

const modelsAcquireQueryDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.configuration,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([]),
);

const modelsSpeechDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.configuration,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("path", ArgumentKind.string),
    ArgumentField("runtime", ArgumentKind.string),
    ArgumentField("digest", ArgumentKind.string),
  ]),
);

const modelsRegisterDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.configuration,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("kind", ArgumentKind.string),
    ArgumentField("path", ArgumentKind.string),
    ArgumentField("runtime", ArgumentKind.string, nullable: true),
    ArgumentField("backend", ArgumentKind.string, nullable: true),
    ArgumentField("digest", ArgumentKind.string, nullable: true),
    ArgumentField("model_type", ArgumentKind.integer, nullable: true),
  ]),
);

const modelsGenerationDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.configuration,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("path", ArgumentKind.string),
    ArgumentField("runtime", ArgumentKind.string),
    ArgumentField("backend", ArgumentKind.string, defaultValue: 'litert_lm'),
    ArgumentField("model_type", ArgumentKind.integer, nullable: true),
  ]),
);

const modelsEmbeddingDescriptor = OperationDescriptor(
  scope: OperationScope.application,
  readOnly: false,
  approval: ApprovalPolicy.desktop,
  capability: CapabilityPolicy.ordinary,
  requiresHelper: true,
  modelGate: ModelGatePolicy.configuration,
  notifiesChanges: true,
  response: ResponseShape.result,
  carriesWorkspaceEpoch: false,
  acceptsIdempotencyKey: false,
  stampsAgentActivity: true,
  leaseBusy: true,
  createsLease: true,
  arguments: OperationArgumentSchema([
    ArgumentField("path", ArgumentKind.string),
    ArgumentField("runtime", ArgumentKind.string, defaultValue: ''),
    ArgumentField("gpu", ArgumentKind.trueSwitch),
    ArgumentField("digest", ArgumentKind.string, nullable: true),
  ]),
);
