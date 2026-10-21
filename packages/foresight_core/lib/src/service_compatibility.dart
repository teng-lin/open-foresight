import 'rpc_error.dart';

/// Internal extraction keeps the released v1 payload contract.
const applicationApiVersion = 1;
const applicationApiVersionField = 'application_api_version';
const applicationClientVersionField = 'client_api_version';

typedef ApplicationStatusProbe =
    Future<Object?> Function(Map<String, dynamic> arguments);

/// Validate on every production initial connection and replacement connection.
/// Transport-only clients can remain handshake-free for protocol fixtures.
void validateApplicationApiVersion(
  Map<String, dynamic> status, {
  String? endpoint,
}) {
  final version = status[applicationApiVersionField];
  if (version is int && version == applicationApiVersion) return;
  final location = endpoint == null ? '' : ' at $endpoint';
  final advertised = version == null
      ? 'did not advertise an API version'
      : 'advertised unsupported API version $version';
  throw RpcError(
    RpcErrorCode.unavailable,
    'Application service$location $advertised; this client requires API '
    'version $applicationApiVersion. Stop the existing service and restart it '
    'with the same app version as this client.',
  );
}

/// An absent field is a released v1 client. Explicit incompatible peers are
/// refused before startup capability/lifetime effects, not implicitly upgraded.
void validateApplicationClientVersion(Object? version) {
  if (version == null) return;
  if (version is! int) {
    throw RpcError(
      RpcErrorCode.invalidArgument,
      '$applicationClientVersionField must be an integer',
    );
  }
  if (version == applicationApiVersion) return;
  throw RpcError(
    RpcErrorCode.unavailable,
    'Client API version $version is unsupported; this service supports API '
    'version $applicationApiVersion. Restart the client and service with the '
    'same app version.',
  );
}

/// Additive v1 status negotiation, with no retry, launch or reconnect policy.
/// Transport errors retain their original code/reason and reach the caller.
Future<Map<String, dynamic>> probeApplicationApiVersion(
  ApplicationStatusProbe probe, {
  Map<String, dynamic> arguments = const {},
  String? endpoint,
}) async {
  final result = await probe({
    ...arguments,
    applicationClientVersionField: applicationApiVersion,
  });
  final status = parseApplicationStatus(result);
  validateApplicationApiVersion(status, endpoint: endpoint);
  return status;
}

/// Decode shape separately so startup can reject a foreign profile before
/// interpreting that owner's version or sending a desktop capability.
Map<String, dynamic> parseApplicationStatus(Object? result) {
  if (result is! Map || result.keys.any((key) => key is! String)) {
    throw RpcError(
      RpcErrorCode.unavailable,
      'Application service returned an invalid status response. Stop the '
      'existing service and restart it with this app.',
    );
  }
  return Map<String, dynamic>.from(result);
}
