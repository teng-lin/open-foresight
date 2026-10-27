import '../operation_descriptor.dart';
import '../client_contract.dart';
import '../client_results.dart';
import '../client_requests/graph.dart';
import '../operation_argument_schema.dart';
import '../graph_clusters.dart';

const graphEmbeddingsDescriptor = OperationDescriptor(
  resultDecoder: ResultCodec(decodeVectors),
  requestEncoder: OperationInputEncoder<GraphEmbeddingsInput>(),
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
  resultDecoder: ResultCodec(decodeNothing),
  requestEncoder: OperationInputEncoder<GraphInvalidateInput>(),
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
  resultDecoder: ResultCodec(decodeNothing),
  requestEncoder: OperationInputEncoder<GraphAcknowledgeInput>(),
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
  resultDecoder: ResultCodec(decodeBoolean),
  requestEncoder: OperationInputEncoder<GraphSaveInput>(),
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
