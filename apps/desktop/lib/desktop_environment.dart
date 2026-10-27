import 'dart:io';
import 'platform_capabilities.dart';

import 'package:foresight_core/desktop.dart'
    show
        DiagnosticSupportPort,
        UnavailableDiagnosticSupport,
        openPlatformUri,
        platformNotification;

export 'platform_capabilities.dart';

typedef DesktopProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef DesktopProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// All host effects are supplied at startup. Widget defaults cannot launch
/// processes or resolve the current user's configuration directories.
class DesktopEnvironment {
  const DesktopEnvironment({
    this.variables = const {},
    this.capabilities = const PlatformCapabilities.linux(),
    String? homeDirectory,
    this.configDirectory = '/dev/null/foresight-config',
    this.dataDirectory = '/dev/null/foresight-data',
    this.launcher = '/dev/null/open-foresight',
    this.run = _noProcess,
    this.start = _noStart,
    this.openUri = _noUri,
    this.notify = _noNotification,
    this.diagnosticSupport = const UnavailableDiagnosticSupport(),
  }) : _homeDirectory = homeDirectory;

  factory DesktopEnvironment.production({
    Map<String, String>? variables,
    bool? macOS,
    PlatformCapabilities? capabilities,
    ProcessResult Function(String, List<String>)? runSync,
  }) {
    final platform =
        capabilities ??
        ((macOS ?? Platform.isMacOS)
            ? const PlatformCapabilities.macOS()
            : const PlatformCapabilities.linux());
    final values = Map<String, String>.unmodifiable(
      variables ?? Platform.environment,
    );
    // Profile resolution remains inside startup's recoverable error surface.
    // Match its account-directory fallback for Finder launches without HOME.
    final home =
        values['HOME'] ??
        (platform.usesAccountHomeLookup
            ? _macHome(runSync ?? Process.runSync)
            : null);
    final hasHome = home != null && home.isNotEmpty;
    return DesktopEnvironment(
      variables: values,
      capabilities: platform,
      homeDirectory: home,
      configDirectory:
          values['XDG_CONFIG_HOME'] ??
          (hasHome ? '$home/.config' : '/dev/null/foresight-config'),
      dataDirectory:
          values['XDG_DATA_HOME'] ??
          (hasHome ? '$home/.local/share' : '/dev/null/foresight-data'),
      launcher:
          '${File(Platform.resolvedExecutable).parent.parent.path}/open-foresight',
      run: Process.run,
      start: Process.start,
      openUri: openPlatformUri,
      notify: platformNotification,
    );
  }

  static String? _macHome(ProcessResult Function(String, List<String>) run) {
    try {
      final user = run('/usr/bin/id', ['-un']);
      if (user.exitCode != 0) return null;
      final result = run('/usr/bin/dscl', [
        '.',
        '-read',
        '/Users/${user.stdout.toString().trim()}',
        'NFSHomeDirectory',
      ]);
      if (result.exitCode != 0) return null;
      final value = result.stdout.toString().trim();
      const prefix = 'NFSHomeDirectory: ';
      return value.startsWith(prefix) ? value.substring(prefix.length) : null;
    } on ProcessException {
      return null;
    }
  }

  final Map<String, String> variables;
  final PlatformCapabilities capabilities;
  final String? _homeDirectory;
  String? get homeDirectory {
    final home = _homeDirectory ?? variables['HOME'];
    return home == null || home.isEmpty ? null : home;
  }

  final String configDirectory, dataDirectory, launcher;
  final DesktopProcessRunner run;
  final DesktopProcessStarter start;
  final Future<void> Function(Uri) openUri;
  final Future<void> Function(String, String) notify;

  /// Startup binds the local logging session's support adapter here; tests
  /// and failed startup keep the inert unavailable port.
  final DiagnosticSupportPort diagnosticSupport;

  DesktopEnvironment withDiagnosticSupport(DiagnosticSupportPort support) =>
      DesktopEnvironment(
        variables: variables,
        capabilities: capabilities,
        homeDirectory: _homeDirectory,
        configDirectory: configDirectory,
        dataDirectory: dataDirectory,
        launcher: launcher,
        run: run,
        start: start,
        openUri: openUri,
        notify: notify,
        diagnosticSupport: support,
      );

  static Future<ProcessResult> _noProcess(
    String executable,
    List<String> args,
  ) => Future.error(UnsupportedError('Host process unavailable: $executable'));
  static Future<Process> _noStart(String executable, List<String> args) =>
      Future.error(UnsupportedError('Host process unavailable: $executable'));
  static Future<void> _noUri(Uri uri) async {}
  static Future<void> _noNotification(String title, String message) async {}
}
