/// Immutable effective configuration. Resolve once, then pass this object to
/// isolates; do not synthesize LOG_LEVEL into a raw environment before parsing.
enum DiagnosticLevel { error, warn, info, debug, trace, off }

final class DiagnosticConfiguration {
  const DiagnosticConfiguration({
    this.level = DiagnosticLevel.info,
    this.transportTrace = false,
    this.invalidLevel = false,
  });
  final DiagnosticLevel level;
  final bool transportTrace;
  final bool invalidLevel;
  bool get enabled => level != DiagnosticLevel.off;
  bool permits(DiagnosticLevel severity, {bool transport = false}) =>
      enabled &&
      severity != DiagnosticLevel.off &&
      (severity.index <= level.index || (transport && transportTrace));
  factory DiagnosticConfiguration.fromEnvironment(
    Map<String, String> environment,
  ) {
    if (environment.containsKey('FORESIGHT_LOG_LEVEL')) {
      final raw = environment['FORESIGHT_LOG_LEVEL'];
      final level = DiagnosticLevel.values
          .where((level) => level.name == raw)
          .firstOrNull;
      return DiagnosticConfiguration(
        level: level ?? DiagnosticLevel.info,
        invalidLevel: level == null,
      );
    }
    return DiagnosticConfiguration(
      transportTrace: environment['FORESIGHT_SERVICE_TRACE'] == '1',
    );
  }
}
