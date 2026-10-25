import 'dart:io';

import 'package:foresight_core/src/diagnostics/startup.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_dispatch.dart';

/// Package-owned runner only. It has no application configuration/profile/SQL
/// imports and never starts another logger. Source contexts need the same
/// reviewed manifest/anchor gate as service self-reexec; missing identity is a
/// closed bootstrap failure, never an environment-selected fallback.
Future<void> main(List<String> arguments) async {
  final invocation = DiagnosticWorkerInvocation.parse(arguments);
  if (invocation.kind != DiagnosticWorkerInvocationKind.valid) {
    exitCode = 64;
    return;
  }
  try {
    final startup = loadDiagnosticChildStartup(
      invocation,
      host: DiagnosticHost.standaloneWorker,
    );
    exitCode = await runDiagnosticStorageWorker(
      functions: startup.functions,
      expectedParentPid: startup.expectedParentPid,
      nativeId: startup.nativeId,
      dartId: startup.dartId,
      catalogId: startup.catalogId,
      verifyBeforeHello: startup.verifyBeforeHello,
    );
  } catch (_) {
    exitCode = 65;
  }
}
