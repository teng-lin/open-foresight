import 'dart:io';
import 'model_catalog.dart';

typedef LocalModelFinder =
    Future<File?> Function(
      GemmaModel model,
      Directory root, {
      Map<String, Object?>? registration,
    });

enum ModelDownloadPhase {
  checkingCache,
  verifyingCache,
  downloading,
  verifyingDownload,
}

class ModelDownloadCancelled implements Exception {
  const ModelDownloadCancelled();
  @override
  String toString() => 'Model download cancelled';
}

/// Download ownership may live in the service. A cancelled subscriber never
/// owns file publication or the underlying transfer's settlement.
abstract interface class ModelDownloader {
  void cancel();
  Future<File> download(
    GemmaModel model,
    Directory root, {
    void Function(int received, int total)? progress,
    void Function(ModelDownloadPhase)? phase,
    Uri? sourceForTesting,
    File? existingFile,
  });
}
