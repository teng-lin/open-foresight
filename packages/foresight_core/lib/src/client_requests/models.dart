import '../client_contract.dart';

final class ModelsDownloadAssetInput extends ClientArguments {
  const ModelsDownloadAssetInput({
    super.envelope,
    required this.kind,
    required this.digest,
    required this.requestId,
    this.progressKey = const WireField.absent(),
  });
  final String kind;
  final String digest;
  final String requestId;
  final WireField<String?> progressKey;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'kind': kind,
    'digest': digest,
    'requestId': requestId,
    if (progressKey.present) 'progress_key': progressKey.value,
  });
}

final class ModelsInspectAssetInput extends ClientArguments {
  const ModelsInspectAssetInput({
    super.envelope,
    required this.kind,
    required this.digest,
  });
  final String kind;
  final String digest;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({'kind': kind, 'digest': digest});
}

final class ModelsCancelQueryAcquisitionInput extends ClientArguments {
  const ModelsCancelQueryAcquisitionInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class ModelsAcquireQueryInput extends ClientArguments {
  const ModelsAcquireQueryInput({super.envelope});
  @override
  Map<String, dynamic> toWire() => envelope.attach({});
}

final class ModelsSpeechInput extends ClientArguments {
  const ModelsSpeechInput({
    super.envelope,
    required this.path,
    required this.runtime,
    required this.digest,
  });
  final String path;
  final String runtime;
  final String digest;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({'path': path, 'runtime': runtime, 'digest': digest});
}

final class ModelsRegisterInput extends ClientArguments {
  const ModelsRegisterInput({
    super.envelope,
    required this.kind,
    required this.path,
    this.runtime = const WireField.absent(),
    this.backend = const WireField.absent(),
    this.digest = const WireField.absent(),
    this.modelType = const WireField.absent(),
    this.gpu = const WireField.absent(),
  });
  final String kind;
  final String path;
  final WireField<String?> runtime;
  final WireField<String?> backend;
  final WireField<String?> digest;
  final WireField<int?> modelType;
  final WireField<bool?> gpu;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'kind': kind,
    'path': path,
    if (runtime.present) 'runtime': runtime.value,
    if (backend.present) 'backend': backend.value,
    if (digest.present) 'digest': digest.value,
    if (modelType.present) 'model_type': modelType.value,
    if (gpu.present) 'gpu': gpu.value,
  });
}

final class ModelsGenerationInput extends ClientArguments {
  const ModelsGenerationInput({
    super.envelope,
    required this.path,
    required this.runtime,
    this.backend = const WireField.absent(),
    this.modelType = const WireField.absent(),
    this.kind = const WireField.absent(),
    this.gpu = const WireField.absent(),
  });
  final String path;
  final String runtime;
  final WireField<String?> backend;
  final WireField<int?> modelType;
  final WireField<String?> kind;
  final WireField<bool?> gpu;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'path': path,
    'runtime': runtime,
    if (backend.present) 'backend': backend.value,
    if (modelType.present) 'model_type': modelType.value,
    if (kind.present) 'kind': kind.value,
    if (gpu.present) 'gpu': gpu.value,
  });
}

final class ModelsEmbeddingInput extends ClientArguments {
  const ModelsEmbeddingInput({
    super.envelope,
    required this.path,
    this.runtime = const WireField.absent(),
    this.gpu = const WireField.absent(),
    this.digest = const WireField.absent(),
    this.kind = const WireField.absent(),
  });
  final String path;
  final WireField<String?> runtime;
  final WireField<bool?> gpu;
  final WireField<String?> digest;
  final WireField<String?> kind;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'path': path,
    if (runtime.present) 'runtime': runtime.value,
    if (gpu.present) 'gpu': gpu.value,
    if (digest.present) 'digest': digest.value,
    if (kind.present) 'kind': kind.value,
  });
}
