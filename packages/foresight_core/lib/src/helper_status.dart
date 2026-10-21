import 'generated/helper_control.pb.dart' as control;

/// Immutable view of the helper owned by the application service.
/// Lifecycle and changes belong to DesktopConnection, never this value.
final class HelperStatus {
  final String state;
  final HelperSnapshot? snapshot;
  const HelperStatus({this.state = 'disconnected', this.snapshot});

  factory HelperStatus.fromEvent(Map<String, Object?> event) {
    final raw = event['helper'];
    final snapshot = raw == null
        ? null
        : HelperSnapshot._fromState(control.State()..mergeFromProto3Json(raw));
    return HelperStatus(
      state:
          event['helper_state'] as String? ??
          (snapshot == null ? 'disconnected' : 'live (service)'),
      snapshot: snapshot,
    );
  }
}

final class HelperSnapshot {
  final String buildId, referenceVersion, instanceId;
  final String pipeline, index, lastError;
  final String activeGeneration;
  final bool tokenizerReady;
  final HelperModelStatus model;

  const HelperSnapshot({
    this.buildId = '',
    this.referenceVersion = '',
    this.instanceId = '',
    this.pipeline = '',
    this.index = '',
    this.lastError = '',
    this.activeGeneration = '0',
    this.tokenizerReady = false,
    this.model = const HelperModelStatus(),
  });

  factory HelperSnapshot._fromState(control.State state) => HelperSnapshot(
    buildId: state.buildId,
    referenceVersion: state.referenceVersion,
    instanceId: state.instanceId,
    pipeline: state.pipeline,
    index: state.index,
    lastError: state.lastError,
    activeGeneration: state.activeGeneration.toString(),
    tokenizerReady: state.tokenizerReady,
    model: HelperModelStatus._fromModel(state.model),
  );
}

final class HelperModelStatus {
  final String modelDigest, tokenizerDigest, preprocessing, backend, path;
  final int dimensions;
  final String identityJson;
  const HelperModelStatus({
    this.modelDigest = '',
    this.tokenizerDigest = '',
    this.preprocessing = '',
    this.backend = '',
    this.path = '',
    this.dimensions = 0,
    this.identityJson = '{}',
  });

  factory HelperModelStatus._fromModel(control.ModelIdentity model) =>
      HelperModelStatus(
        modelDigest: model.modelDigest,
        tokenizerDigest: model.tokenizerDigest,
        preprocessing: model.preprocessing,
        backend: model.backend,
        path: model.path,
        dimensions: model.dimensions,
        // Preserve the current graph identity's exact protobuf JSON semantics.
        // Serializing a reconstructed ordinary map could invalidate its cache.
        identityJson: model.writeToJson(),
      );

  String writeToJson() => identityJson;
}
