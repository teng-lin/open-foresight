/// Transport and startup capabilities for remote adapters. This entry point
/// never imports the service composition root or native runtime ownership.
library;

export 'src/service_client.dart' show ServiceClient, cancellableAnswers;
export 'src/service_connection.dart' show ServiceConnection;
export 'src/service_startup.dart' show ensureService, ensureServiceSnapshot;
export 'src/profile_paths.dart' show ProfilePaths;
export 'src/operations.dart' show Operation;
export 'src/rpc_error.dart' show RpcError, RpcErrorCode, RpcErrorReason;
