import '../operations.dart';
import 'request_context.dart';

class LabelsAutoAssignRequest extends OperationRequest {
  LabelsAutoAssignRequest._(super.context, this.name);
  final String name;
  @override
  Operation get operation => Operation.labelsAutoAssign;
  factory LabelsAutoAssignRequest.decode(OperationRequestContext context) {
    final values = Operation.labelsAutoAssign.descriptor.arguments.decode(
      context.rawArguments,
    );
    return LabelsAutoAssignRequest._(context, values.value<String>("name"));
  }
}

class LabelsPutRequest extends OperationRequest {
  LabelsPutRequest._(
    super.context,
    this.id,
    this.name,
    this.source,
    this.color,
    this.rationale,
  );
  final String id;
  final String name;
  final String source;
  final String? color;
  final String? rationale;
  @override
  Operation get operation => Operation.labelsPut;
  factory LabelsPutRequest.decode(OperationRequestContext context) {
    final values = Operation.labelsPut.descriptor.arguments.decode(
      context.rawArguments,
    );
    return LabelsPutRequest._(
      context,
      values.value<String>("id"),
      values.value<String>("name"),
      values.value<String>("source"),
      values.value<String?>("color"),
      values.value<String?>("rationale"),
    );
  }
}

class LabelsSetRequest extends OperationRequest {
  LabelsSetRequest._(super.context, this.id, this.labels);
  final String id;
  final List<String> labels;
  @override
  Operation get operation => Operation.labelsSet;
  factory LabelsSetRequest.decode(OperationRequestContext context) {
    final values = Operation.labelsSet.descriptor.arguments.decode(
      context.rawArguments,
    );
    return LabelsSetRequest._(
      context,
      values.value<String>("id"),
      values.value<List<String>>("labels"),
    );
  }
}

class LabelsClusterRequest extends OperationRequest {
  LabelsClusterRequest._(super.context, this.name);
  final String name;
  @override
  Operation get operation => Operation.labelsCluster;
  factory LabelsClusterRequest.decode(OperationRequestContext context) {
    final values = Operation.labelsCluster.descriptor.arguments.decode(
      context.rawArguments,
    );
    return LabelsClusterRequest._(context, values.value<String>("name"));
  }
}

class LabelsDeleteRequest extends OperationRequest {
  LabelsDeleteRequest._(super.context, this.name);
  final String name;
  @override
  Operation get operation => Operation.labelsDelete;
  factory LabelsDeleteRequest.decode(OperationRequestContext context) {
    final values = Operation.labelsDelete.descriptor.arguments.decode(
      context.rawArguments,
    );
    return LabelsDeleteRequest._(context, values.value<String>("name"));
  }
}
