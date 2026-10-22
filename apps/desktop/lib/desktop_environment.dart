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

  factory DesktopEnvironment.production() {
    final variables = Map<String, String>.unmodifiable(Platform.environment);
    final home = variables['HOME']!;
    return DesktopEnvironment(
      variables: variables,
      configDirectory: variables['XDG_CONFIG_HOME'] ?? '$home/.config',
      dataDirectory: variables['XDG_DATA_HOME'] ?? '$home/.local/share',
      launcher:
          '${File(Platform.resolvedExecutable).parent.parent.path}/open-foresight',
      run: Process.run,
      start: Process.start,
      openUri: openPlatformUri,
      notify: platformNotification,
    );
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
