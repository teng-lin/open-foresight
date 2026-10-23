import 'dart:io';
import 'package:foresight_core/desktop.dart'
    show openPlatformUri, platformNotification;

typedef DesktopProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef DesktopProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// All host effects are supplied at startup. Widget defaults cannot launch
/// processes or resolve the current user's configuration directories.
class DesktopEnvironment {
  const DesktopEnvironment({
    this.variables = const {},
    this.configDirectory = '/dev/null/foresight-config',
    this.dataDirectory = '/dev/null/foresight-data',
    this.launcher = '/dev/null/open-foresight',
    this.run = _noProcess,
    this.start = _noStart,
    this.openUri = _noUri,
    this.notify = _noNotification,
  });

  factory DesktopEnvironment.production({
    Map<String, String>? variables,
    bool? macOS,
    ProcessResult Function(String, List<String>)? runSync,
  }) {
    final values = Map<String, String>.unmodifiable(
      variables ?? Platform.environment,
    );
    // Profile resolution remains inside startup's recoverable error surface.
    // Match its account-directory fallback for Finder launches without HOME.
    final home =
        values['HOME'] ??
        ((macOS ?? Platform.isMacOS)
            ? _macHome(runSync ?? Process.runSync)
            : null);
    return DesktopEnvironment(
      variables: values,
      configDirectory:
          values['XDG_CONFIG_HOME'] ??
          (home == null ? '/dev/null/foresight-config' : '$home/.config'),
      dataDirectory:
          values['XDG_DATA_HOME'] ??
          (home == null ? '/dev/null/foresight-data' : '$home/.local/share'),
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
  final String configDirectory, dataDirectory, launcher;
  final DesktopProcessRunner run;
  final DesktopProcessStarter start;
  final Future<void> Function(Uri) openUri;
  final Future<void> Function(String, String) notify;

  static Future<ProcessResult> _noProcess(
    String executable,
    List<String> args,
  ) => Future.error(UnsupportedError('Host process unavailable: $executable'));
  static Future<Process> _noStart(String executable, List<String> args) =>
      Future.error(UnsupportedError('Host process unavailable: $executable'));
  static Future<void> _noUri(Uri uri) async {}
  static Future<void> _noNotification(String title, String message) async {}
}
