/// Support access to this process's local diagnostics, available to desktop
/// features. Values are closed enums, booleans and bounded counters only:
/// never paths, URLs, account, profile, model or content data, exception text
/// or stacks. Nothing here uploads, exports or sends logs anywhere.
library;

/// The process a snapshot describes. The background service and MCP clients
/// keep their own sessions in the same logs folder; their health is not part
/// of a desktop snapshot.
enum DiagnosticSupportHost { desktop }

/// Effective FORESIGHT_LOG_LEVEL of the session.
enum DiagnosticSupportLevel { error, warn, info, debug, trace, off }

/// User-facing summary of [DiagnosticSupportReason].
enum DiagnosticSupportStatus {
  /// No logging session is attached, for example after a startup failure.
  unavailable,

  /// FORESIGHT_LOG_LEVEL=off: nothing is recorded.
  off,

  /// Recording without a known fault.
  active,

  /// Records are held in memory only and are not written to files.
  memoryOnly,

  /// Log files cannot be written here; the application continues.
  limited,

  /// File logging stopped after a failure; the application continues.
  failed,

  /// The session closed normally.
  closed,
}

/// Closed health reasons of the logging session, plus [unavailable] when no
/// session is attached.
enum DiagnosticSupportReason {
  unavailable,
  healthy,
  bootstrapOnly,
  off,
  storageUnavailable,
  unsupportedFilesystem,
  sinkFailed,
  writerFailed,
  closed,
  storageWorkerUnconfigured,
  storageStagingUnavailable,
  storagePlatformUnsupported,
  storageDescriptorLimit,
  storageWorkerLaunchFailed,
  storageWorkerProtocolFailed,
  storageWorkerExited,
  storageWorkerUnresponsive,
  storageWorkerUnknown;

  DiagnosticSupportStatus get status => switch (this) {
    unavailable => DiagnosticSupportStatus.unavailable,
    off => DiagnosticSupportStatus.off,
    healthy => DiagnosticSupportStatus.active,
    bootstrapOnly => DiagnosticSupportStatus.memoryOnly,
    closed => DiagnosticSupportStatus.closed,
    storageUnavailable ||
    unsupportedFilesystem ||
    storageWorkerUnconfigured ||
    storageStagingUnavailable ||
    storagePlatformUnsupported ||
    storageDescriptorLimit => DiagnosticSupportStatus.limited,
    sinkFailed ||
    writerFailed ||
    storageWorkerLaunchFailed ||
    storageWorkerProtocolFailed ||
    storageWorkerExited ||
    storageWorkerUnresponsive ||
    storageWorkerUnknown => DiagnosticSupportStatus.failed,
  };
}

/// Closed outcome of revealing the logs folder. Failures never carry opener
/// output, error text or the path.
enum DiagnosticFolderOpenResult {
  /// The local platform opener accepted the folder.
  opened,

  /// No profile logs folder is known to this session.
  unavailable,

  /// The folder does not exist yet; nothing has been written to files.
  missing,

  /// The folder is a link, not a directory, or not private; it was not opened.
  unsafe,

  /// The local platform opener failed.
  failed,
}

const _maximumCounter = 0x7fffffff;
int _bounded(int value) => value.clamp(0, _maximumCounter);

/// An immutable copy of in-memory session health and effective configuration.
final class DiagnosticSupportSnapshot {
  DiagnosticSupportSnapshot({
    required this.reason,
    this.host = DiagnosticSupportHost.desktop,
    this.level = DiagnosticSupportLevel.off,
    this.invalidLevel = false,
    this.transportTrace = false,
    this.closed = false,
    this.logsFolderKnown = false,
    int admitted = 0,
    int dropped = 0,
    int rejected = 0,
    int refusedProducers = 0,
    int quarantinedProducers = 0,
  }) : admitted = _bounded(admitted),
       dropped = _bounded(dropped),
       rejected = _bounded(rejected),
       refusedProducers = _bounded(refusedProducers),
       quarantinedProducers = _bounded(quarantinedProducers);

  const DiagnosticSupportSnapshot._unavailable()
    : reason = DiagnosticSupportReason.unavailable,
      host = DiagnosticSupportHost.desktop,
      level = DiagnosticSupportLevel.off,
      invalidLevel = false,
      transportTrace = false,
      closed = false,
      logsFolderKnown = false,
      admitted = 0,
      dropped = 0,
      rejected = 0,
      refusedProducers = 0,
      quarantinedProducers = 0;

  static const unavailable = DiagnosticSupportSnapshot._unavailable();

  final DiagnosticSupportReason reason;
  final DiagnosticSupportHost host;
  final DiagnosticSupportLevel level;
  final bool invalidLevel, transportTrace, closed;

  /// Whether this session knows its selected profile's logs folder. It does
  /// not claim that the folder exists.
  final bool logsFolderKnown;

  /// Saturating session counters.
  final int admitted, dropped, rejected, refusedProducers, quarantinedProducers;

  DiagnosticSupportStatus get status => reason.status;

  /// Plain text a user may review and paste into a bug report. It contains
  /// only the closed fields above.
  String get supportText => [
    'host: ${host.name}',
    'status: ${status.name}',
    'reason: ${reason.name}',
    'level: ${level.name}',
    'invalid_level: $invalidLevel',
    'transport_trace: $transportTrace',
    'closed: $closed',
    'logs_folder_known: $logsFolderKnown',
    'admitted: $admitted',
    'dropped: $dropped',
    'rejected: $rejected',
    'producer_registration_refused: $refusedProducers',
    'producer_quarantined: $quarantinedProducers',
  ].join('\n');
}

/// Supplied to desktop features at startup.
abstract interface class DiagnosticSupportPort {
  /// Copies in-memory health. Performs no I/O, allocates or registers no
  /// diagnostic producer and sends no message to the writer.
  DiagnosticSupportSnapshot snapshot();

  /// Reveals the selected profile's logs folder with the local platform
  /// opener. Never creates the folder and never uploads anything.
  Future<DiagnosticFolderOpenResult> openLogsFolder();
}

/// Inert default for tests and failed startup: reports [unavailable] and
/// performs no effect.
final class UnavailableDiagnosticSupport implements DiagnosticSupportPort {
  const UnavailableDiagnosticSupport();

  @override
  DiagnosticSupportSnapshot snapshot() => DiagnosticSupportSnapshot.unavailable;

  @override
  Future<DiagnosticFolderOpenResult> openLogsFolder() =>
      Future.value(DiagnosticFolderOpenResult.unavailable);
}
