import 'rpc_error.dart';

// Answers the service gives about a request's key or workspace rather than
// its effect. A client can rely on them even after an earlier attempt under
// the same key lost its reply.

const workspaceClearedItemMessage =
    'This item was removed when the workspace was cleared.';
const workspaceClearedChangeMessage =
    'The workspace was cleared after this change was prepared; nothing was saved.';
const keyReusedWithOtherArgumentsMessage =
    'This idempotency_key was already used with different arguments.';
const _keyReusedForPrefix = 'This idempotency_key was already used for ';
String keyReusedForMessage(String operation) =>
    '$_keyReusedForPrefix$operation.';

/// The request was prepared in a workspace that has since been cleared.
bool isWorkspaceCleared(Object error) =>
    error is RpcError &&
    error.code == RpcErrorCode.notFound &&
    (error.message == workspaceClearedItemMessage ||
        error.message == workspaceClearedChangeMessage);

/// The request's idempotency key belongs to another operation or arguments.
bool isKeyConflict(Object error) =>
    error is RpcError &&
    error.code == RpcErrorCode.invalidArgument &&
    (error.message == keyReusedWithOtherArgumentsMessage ||
        error.message.startsWith(_keyReusedForPrefix));
