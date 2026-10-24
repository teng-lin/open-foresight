import 'dart:async';
import 'dart:io';

import 'desktop_connection.dart';
import 'model_asset_status.dart';
import 'model_catalog.dart';
import 'model_download_contract.dart';
import 'operations.dart';
import 'speech_model_catalog.dart';

String _kind(GemmaModel model) {
  if (model.digest == embeddingGemmaModel.digest) return 'embedding';
  if (gemmaModels.any((candidate) => candidate.digest == model.digest)) {
    return 'generation';
  }
  if (speechModels.any((candidate) => candidate.digest == model.digest)) {
    return 'speech';
  }
  throw ArgumentError('Unsupported pinned model asset');
}

final class DesktopModelAssetClient {
  DesktopModelAssetClient(this.connection, {this.current});
  final DesktopConnection connection;
  final bool Function()? current;
  Future<File?> findLocalModel(
    GemmaModel model,
    Directory root, {
    Map<String, Object?>? registration,
  }) async {
    final result = await connection.commandCurrent(
      Operation.modelsInspectAsset,
      {'kind': _kind(model), 'digest': model.digest},
      current ?? () => true,
    );
    final location = ModelAssetLocation.fromWire(result, requiredPath: false);
    return location.path == null ? null : File(location.path!);
  }
}

/// The desktop owns its subscription and cancellation token. The service owns
/// transfer, resumable files, publication and actual worker settlement.
final class RemoteModelDownloader implements ModelDownloader {
  RemoteModelDownloader(this.connection, {this.ownerCurrent});
  final DesktopConnection connection;
  final bool Function()? ownerCurrent;
  static int _next = 0;
  bool _cancelled = false, _active = false;
  @override
  void cancel() => _cancelled = true;
  @override
  Future<File> download(
    GemmaModel model,
    Directory root, {
    void Function(int, int)? progress,
    void Function(ModelDownloadPhase)? phase,
    Uri? sourceForTesting,
    File? existingFile,
  }) async {
    if (_active || _cancelled) throw const ModelDownloadCancelled();
    if (sourceForTesting != null) {
      throw ArgumentError('Remote downloads use pinned service metadata');
    }
    _active = true;
    final requestId =
        'model-asset-${DateTime.now().microsecondsSinceEpoch}-${++_next}';
    bool current() => !_cancelled && (ownerCurrent?.call() ?? true);
    final callbackFailed = Completer<Object?>();
    Object? callbackFailure;
    final subscription = connection.changes.listen((_) {
      final source = connection;
      if (!current() || source is! ModelAssetProgressSource) return;
      final state = (source as ModelAssetProgressSource).modelAssetDownload;
      if (state.requestId != requestId || state.digest != model.digest) return;
      try {
        phase?.call(state.phase);
        if (state.total > 0) progress?.call(state.received, state.total);
      } catch (error, stack) {
        _cancelled = true;
        callbackFailure = error;
        if (!callbackFailed.isCompleted) {
          callbackFailed.completeError(error, stack);
        }
      }
    });
    try {
      final result = await Future.any<Object?>([
        connection.commandCurrent(Operation.modelsDownloadAsset, {
          'kind': _kind(model),
          'digest': model.digest,
          'requestId': requestId,
        }, current),
        callbackFailed.future,
      ]);
      if (!current()) throw const ModelDownloadCancelled();
      return File(
        ModelAssetLocation.fromWire(result, requiredPath: true).path!,
      );
    } catch (error) {
      if (identical(error, callbackFailure)) rethrow;
      if (_cancelled || !(ownerCurrent?.call() ?? true)) {
        throw const ModelDownloadCancelled();
      }
      rethrow;
    } finally {
      await subscription.cancel();
      _active = false;
    }
  }
}
