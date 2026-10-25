/// Application composition only. Worker entrypoints import diagnostics/startup
/// directly and never import this SQL/session authority.
library;

import 'dart:io';

import '../persistence_bootstrap.dart';
import 'diagnostics/session.dart';
import 'diagnostics/startup.dart';
import 'version.dart';

/// One process entrypoint prepares native images before any profile/app locks,
/// then starts its session before application initialization. Feature code gets
/// producer handles, never this composition capability.
final class ApplicationRuntimeBootstrap {
  const ApplicationRuntimeBootstrap._(this.host, this.diagnostics);
  final DiagnosticHost host;
  final DiagnosticStartup diagnostics;

  static ApplicationRuntimeBootstrap prepare(DiagnosticHost host) {
    final context = DiagnosticStartupContext.current(host);
    final diagnostics = DiagnosticStartup.beforeApplication(
      environment: Platform.environment,
      context: context,
    );
    if (host == DiagnosticHost.service || host == DiagnosticHost.desktop) {
      final runtime = RuntimeSupportSelection.resolve(context);
      initializeSqliteRuntime(supportLibrary: runtime.sqlSupport);
    }
    return ApplicationRuntimeBootstrap._(host, diagnostics);
  }

  Future<LoggingSession> startDiagnostics({String? profilePath}) {
    final functions = diagnostics.functions;
    final selection = diagnostics.selection;
    return LoggingSession.start(
      configuration: diagnostics.configuration,
      profilePath: profilePath,
      role: switch (host) {
        DiagnosticHost.service => DiagnosticRole.candidate,
        DiagnosticHost.desktop => DiagnosticRole.desktop,
        DiagnosticHost.mcp => DiagnosticRole.mcp,
        DiagnosticHost.standaloneWorker => DiagnosticRole.transient,
      },
      version: openForesightVersion,
      revision: const String.fromEnvironment(
        'FORESIGHT_RUNTIME_REVISION',
        defaultValue: 'unknown',
      ),
      workerFactory: functions == null || selection == null
          ? null
          : (context) => NativeDiagnosticWorkerOwner(
              context,
              functions,
              resolveCommand: () => selection.command(context.applicationPid),
            ),
    );
  }
}
