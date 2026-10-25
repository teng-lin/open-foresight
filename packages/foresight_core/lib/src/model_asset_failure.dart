import 'rpc_error.dart';

/// Closed public-asset failure vocabulary. Worker diagnostics and exception
/// strings never become protocol or product text.
enum ModelAssetFailureCode { diskSpace, interrupted, hash, https, invalid }

final class ModelAssetFailure extends StateError {
  ModelAssetFailure(this.code, {this.requiredBytes})
    : super(_message(code, requiredBytes));
  final ModelAssetFailureCode code;
  final int? requiredBytes;
  static String _message(
    ModelAssetFailureCode code,
    int? bytes,
  ) => switch (code) {
    ModelAssetFailureCode.diskSpace when bytes != null && bytes > 0 =>
      'Not enough free disk space. Model setup needs ${(bytes / 1e9).toStringAsFixed(2)} GB of free space.',
    ModelAssetFailureCode.diskSpace =>
      'Unable to check free disk space for model download.',
    ModelAssetFailureCode.interrupted =>
      'Model transfer interrupted. Retry to resume the saved download.',
    ModelAssetFailureCode.hash =>
      'Model download failed size or hash verification. Retry the download.',
    ModelAssetFailureCode.https => 'Model downloads require HTTPS.',
    ModelAssetFailureCode.invalid =>
      'Unable to download or load this model. Retry or use local model setup.',
  };
  RpcError toRpcError() =>
      RpcError(RpcErrorCode.unavailable, message.toString());
}

const modelTermsRequiredMessage =
    'Review and accept the pinned model terms before downloading';
const modelDownloadBusyMessage = 'A model download is already active';
const modelRuntimeUnavailableMessage = 'The local Gemma runtime is unavailable';
const modelRuntimeNotReadyMessage = 'The local Gemma runtime is not ready';
const modelAcquisitionClosedMessage = 'Model acquisition is closed';
const modelAcquisitionRestartMessage =
    'Model setup could not confirm that its runtime stopped. Restart the application service before trying again.';

/// Used only by model setup surfaces. Even arbitrary RpcError/StateError values
/// cannot display a path, authenticated URL or diagnostic from another layer.
String modelSetupFailureMessage(Object failure) {
  final message = failure is RpcError
      ? failure.message
      : failure is ModelAssetFailure
      ? failure.message.toString()
      : '';
  final allowed = {
    modelTermsRequiredMessage,
    modelDownloadBusyMessage,
    modelRuntimeUnavailableMessage,
    modelRuntimeNotReadyMessage,
    modelAcquisitionClosedMessage,
    modelAcquisitionRestartMessage,
    for (final code in ModelAssetFailureCode.values)
      ModelAssetFailure(code).message,
  };
  if (allowed.contains(message) ||
      RegExp(
        r'^Not enough free disk space\. Model setup needs [0-9]{1,9}\.[0-9]{2} GB of free space\.$',
      ).hasMatch(message)) {
    return message;
  }
  return ModelAssetFailure(ModelAssetFailureCode.invalid).message.toString();
}
