import 'model_download_contract.dart';
import 'rpc_error.dart';

extension ModelDownloadPhaseWire on ModelDownloadPhase {
  String get wire => switch (this) {
    ModelDownloadPhase.checkingCache => 'checking_cache',
    ModelDownloadPhase.verifyingCache => 'verifying_cache',
    ModelDownloadPhase.downloading => 'downloading',
    ModelDownloadPhase.verifyingDownload => 'verifying_download',
  };
}

/// A malformed reply may follow a committed operation. Keep its outcome unknown;
/// it must never grant a caller permission to repeat a sent write as not-sent.
final class ModelAssetLocation {
  const ModelAssetLocation(this.path);
  final String? path;
  factory ModelAssetLocation.fromWire(
    Object? value, {
    required bool requiredPath,
  }) {
    if (value is! Map ||
        !value.containsKey('path') ||
        value['path'] == '' ||
        (value['path'] != null && value['path'] is! String) ||
        (requiredPath && (value['path'] == null || value['path'] == ''))) {
      throw RpcError(
        RpcErrorCode.internal,
        'Invalid model asset response',
        reason: RpcErrorReason.outcomeUnknown,
      );
    }
    return ModelAssetLocation(value['path'] as String?);
  }
  Map<String, Object?> toWire() => {'path': path};
}

final class ModelAssetDownloadPresentation {
  const ModelAssetDownloadPresentation({
    this.requestId = '',
    this.digest = '',
    this.active = false,
    this.restartRequired = false,
    this.phase = ModelDownloadPhase.checkingCache,
    this.received = 0,
    this.total = 0,
  });
  final String requestId, digest;
  final bool active, restartRequired;
  final ModelDownloadPhase phase;
  final int received, total;
  factory ModelAssetDownloadPresentation.fromWire(Object? value) {
    if (value == null) return const ModelAssetDownloadPresentation();
    final state = Map<String, Object?>.from(value as Map);
    return ModelAssetDownloadPresentation(
      requestId: state['request_id'] as String? ?? '',
      digest: state['digest'] as String? ?? '',
      active: state['active'] == true,
      restartRequired: state['restart_required'] == true,
      phase:
          ModelDownloadPhase.values
              .where((phase) => phase.wire == state['phase'])
              .firstOrNull ??
          ModelDownloadPhase.checkingCache,
      received: state['received'] as int? ?? 0,
      total: state['total'] as int? ?? 0,
    );
  }
  Map<String, Object?> toWire() => {
    'request_id': requestId,
    'digest': digest,
    'active': active,
    'restart_required': restartRequired,
    'phase': phase.wire,
    'received': received,
    'total': total,
  };
}

/// Optional service progress, independent of the desktop's read-only store.
abstract interface class ModelAssetProgressSource {
  ModelAssetDownloadPresentation get modelAssetDownload;
}
