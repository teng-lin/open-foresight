import '../operations.dart';
import 'request_context.dart';
import '../graph_clusters.dart';
import '../graph_layout.dart';
import 'graph_inputs.dart';

class GraphEmbeddingsRequest extends OperationRequest {
  GraphEmbeddingsRequest._(super.context, this.sources);
  final List<GraphSourceInput> sources;
  @override
  Operation get operation => Operation.graphEmbeddings;
  factory GraphEmbeddingsRequest.decode(OperationRequestContext context) {
    final values = Operation.graphEmbeddings.descriptor.arguments.decode(
      context.rawArguments,
    );
    return GraphEmbeddingsRequest._(
      context,
      values.value<List<GraphSourceInput>>("sources"),
    );
  }
}

class GraphInvalidateRequest extends OperationRequest {
  GraphInvalidateRequest._(super.context);
  @override
  Operation get operation => Operation.graphInvalidate;
  factory GraphInvalidateRequest.decode(OperationRequestContext context) {
    return GraphInvalidateRequest._(context);
  }
}

class GraphAcknowledgeRequest extends OperationRequest {
  GraphAcknowledgeRequest._(super.context);
  @override
  Operation get operation => Operation.graphAcknowledge;
  factory GraphAcknowledgeRequest.decode(OperationRequestContext context) {
    return GraphAcknowledgeRequest._(context);
  }
}

class GraphSaveRequest extends OperationRequest {
  GraphSaveRequest._(
    super.context,
    this.identity,
    this.sources,
    this.vectors,
    this.points,
    this.labelSet,
    this.clusters,
  );
  final String identity;
  final List<GraphSourceInput> sources;
  final Map<String, List<double>> vectors;
  final Map<String, GraphPoint> points;
  final String? labelSet;
  final List<GraphCluster> clusters;
  @override
  Operation get operation => Operation.graphSave;
  factory GraphSaveRequest.decode(OperationRequestContext context) {
    final values = Operation.graphSave.descriptor.arguments.decode(
      context.rawArguments,
    );
    return GraphSaveRequest._(
      context,
      values.value<String>("identity"),
      values.value<List<GraphSourceInput>>("sources"),
      values.value<Map<String, List<double>>>("vectors"),
      values.value<Map<String, GraphPoint>>("points"),
      values.value<String?>("labelSet"),
      values.value<List<GraphCluster>>("clusters"),
    );
  }
}
