import 'dart:async';
import 'dart:io';

import 'service_workspace_ports.dart';
import '../persistence/application_queries.dart';
import '../proactive_questions.dart';
import '../rpc_error.dart';
import '../platform_services.dart';

abstract interface class WorkspaceAccountCleanup {
  void forgetWorkspaceAccounts();
}

/// Owns the clear transaction and its post-commit cleanup, on the existing
/// domain writer. The caller cancels feature-owned work before entering here.
final class WorkspaceAdmin {
  WorkspaceAdmin({
    required this.domain,
    required this.persistence,
    required this.proactive,
    required this.accounts,
  });

  final WorkspaceResetPort domain;
  final WorkspacePersistence persistence;
  final ProactiveQuestions proactive;
  final WorkspaceAccountCleanup accounts;
  bool _clearing = false;
  bool get clearing => _clearing;

  Future<ClearedWorkspace> clear() async {
    if (_clearing) {
      throw RpcError(RpcErrorCode.busy, 'Workspace is being cleared');
    }
    _clearing = true;
    Future<void>? reset;
    try {
      final sourceIds = persistence.sourceIds;
      domain.invalidateWorkspace();
      reset = proactive.reset();
      final result = persistence.clearLocalData(sourceIds);
      // The durable privacy marker was committed with the deletion. A busy
      // reader can defer physical erasure without undoing the local clear.
      persistence.store.compactAfterClear();
      domain.cleanupClearedSources(result.sourceIds);
      accounts.forgetWorkspaceAccounts();
      sweepStaleSpeechAudio(File(persistence.store.path).parent.path);
      return result;
    } finally {
      // A cancellation acknowledgement is not settlement. IDs cannot be reused
      // while automatic work from the preceding workspace is still draining.
      try {
        await reset;
      } finally {
        _clearing = false;
      }
    }
  }
}
