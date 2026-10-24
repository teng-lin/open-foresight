import '../operations.dart';
import 'request_context.dart';
import '../operation_argument_schema.dart';

class ModelsDownloadAssetRequest extends OperationRequest {
  ModelsDownloadAssetRequest._(super.context, this.kind, this.digest);
  final String kind, digest;
  @override
  Operation get operation => Operation.modelsDownloadAsset;
  factory ModelsDownloadAssetRequest.decode(OperationRequestContext context) {
    final values = Operation.modelsDownloadAsset.descriptor.arguments.decode(
      context.rawArguments,
    );
    if (context.requestId == null || context.requestId!.isEmpty) {
      invalidArgument('requestId', 'is required');
    }
    return ModelsDownloadAssetRequest._(
      context,
      values.value<String>('kind'),
      values.value<String>('digest'),
    );
  }
}

class ModelsInspectAssetRequest extends OperationRequest {
  ModelsInspectAssetRequest._(super.context, this.kind, this.digest);
  final String kind, digest;
  @override
  Operation get operation => Operation.modelsInspectAsset;
  factory ModelsInspectAssetRequest.decode(OperationRequestContext context) {
    final values = Operation.modelsInspectAsset.descriptor.arguments.decode(
      context.rawArguments,
    );
    return ModelsInspectAssetRequest._(
      context,
      values.value<String>('kind'),
      values.value<String>('digest'),
    );
  }
}

class ModelsCancelQueryAcquisitionRequest extends OperationRequest {
  ModelsCancelQueryAcquisitionRequest._(super.context);
  @override
  Operation get operation => Operation.modelsCancelQueryAcquisition;
  factory ModelsCancelQueryAcquisitionRequest.decode(
    OperationRequestContext context,
  ) {
    return ModelsCancelQueryAcquisitionRequest._(context);
  }
}

class ModelsAcquireQueryRequest extends OperationRequest {
  ModelsAcquireQueryRequest._(super.context);
  @override
  Operation get operation => Operation.modelsAcquireQuery;
  factory ModelsAcquireQueryRequest.decode(OperationRequestContext context) {
    return ModelsAcquireQueryRequest._(context);
  }
}

class ModelsSpeechRequest extends OperationRequest {
  ModelsSpeechRequest._(super.context, this.path, this.runtime, this.digest);
  final String path;
  final String runtime;
  final String digest;
  @override
  Operation get operation => Operation.modelsSpeech;
  factory ModelsSpeechRequest.decode(OperationRequestContext context) {
    final values = Operation.modelsSpeech.descriptor.arguments.decode(
      context.rawArguments,
    );
    return ModelsSpeechRequest._(
      context,
      values.value<String>("path"),
      values.value<String>("runtime"),
      values.value<String>("digest"),
    );
  }
}

class ModelsRegisterRequest extends OperationRequest {
  ModelsRegisterRequest._(
    super.context,
    this.kind,
    this.path,
    this.runtime,
    this.backend,
    this.digest,
    this.modelType,
  );
  final String kind;
  final String path;
  final String? runtime;
  final String? backend;
  final String? digest;
  final int? modelType;
  @override
  Operation get operation => Operation.modelsRegister;
  factory ModelsRegisterRequest.decode(OperationRequestContext context) {
    final values = Operation.modelsRegister.descriptor.arguments.decode(
      context.rawArguments,
    );
    if (values.value<String>('kind') == 'query-detection' &&
        values.value<String?>('backend') == 'raw_query_jsonl_v1') {
      if (values.value<String?>('runtime') == null) {
        invalidArgument('runtime', 'is required for portable query models');
      }
      if (values.value<String?>('digest') == null) {
        invalidArgument('digest', 'is required for portable query models');
      }
    }
    return ModelsRegisterRequest._(
      context,
      values.value<String>("kind"),
      values.value<String>("path"),
      values.value<String?>("runtime"),
      values.value<String?>("backend"),
      values.value<String?>("digest"),
      values.value<int?>("model_type"),
    );
  }
}

class ModelsGenerationRequest extends OperationRequest {
  ModelsGenerationRequest._(
    super.context,
    this.path,
    this.runtime,
    this.backend,
    this.modelType,
  );
  final String path;
  final String runtime;
  final String backend;
  final int? modelType;
  @override
  Operation get operation => Operation.modelsGeneration;
  factory ModelsGenerationRequest.decode(OperationRequestContext context) {
    final values = Operation.modelsGeneration.descriptor.arguments.decode(
      context.rawArguments,
    );
    return ModelsGenerationRequest._(
      context,
      values.value<String>("path"),
      values.value<String>("runtime"),
      values.value<String>("backend"),
      values.value<int?>("model_type"),
    );
  }
}

class ModelsEmbeddingRequest extends OperationRequest {
  ModelsEmbeddingRequest._(
    super.context,
    this.path,
    this.runtime,
    this.gpu,
    this.digest,
  );
  final String path;
  final String runtime;
  final bool gpu;
  final String? digest;
  @override
  Operation get operation => Operation.modelsEmbedding;
  factory ModelsEmbeddingRequest.decode(OperationRequestContext context) {
    final values = Operation.modelsEmbedding.descriptor.arguments.decode(
      context.rawArguments,
    );
    return ModelsEmbeddingRequest._(
      context,
      values.value<String>("path"),
      values.value<String>("runtime"),
      values.value<bool>("gpu"),
      values.value<String?>("digest"),
    );
  }
}
