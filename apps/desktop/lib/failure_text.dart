import 'package:foresight_core/remote.dart';

/// Shown when a request was sent but its reply was lost: it may have
/// committed, so the desktop never reports it as a plain disconnect.
const outcomeUnknownText =
    'The service stopped before confirming; it may have completed. '
    'Check whether it was saved.';

/// The text the desktop shows for a failed request.
String failureText(Object failure) {
  if (failure is RpcError && failure.reason == RpcErrorReason.outcomeUnknown) {
    return outcomeUnknownText;
  }
  return failure is StateError ? failure.message.toString() : '$failure';
}

/// Whether [failure] left the request's outcome unknown, so views should be
/// read again from the profile.
bool outcomeUnknown(Object failure) =>
    failure is RpcError && failure.reason == RpcErrorReason.outcomeUnknown;
