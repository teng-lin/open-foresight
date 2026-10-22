import '../operation_descriptor.dart';
import '../operation_argument_schema.dart';
import '../graph_clusters.dart';

const graphEmbeddingsDescriptor = OperationDescriptor(
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
    ArgumentField("sources", ArgumentKind.graphSources),
  ]),
);

const graphInvalidateDescriptor = OperationDescriptor(
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

const graphAcknowledgeDescriptor = OperationDescriptor(
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

const graphSaveDescriptor = OperationDescriptor(
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
    ArgumentField("identity", ArgumentKind.string),
    ArgumentField("sources", ArgumentKind.graphSources),
    ArgumentField("vectors", ArgumentKind.vectors),
    ArgumentField("points", ArgumentKind.points),
    ArgumentField("labelSet", ArgumentKind.string, nullable: true),
    ArgumentField(
      "clusters",
      ArgumentKind.clusters,
      defaultValue: <GraphCluster>[],
    ),
  ]),
);
