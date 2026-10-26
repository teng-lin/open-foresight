/// Support access to this process's local diagnostics, available to desktop
/// features. Values are closed enums, booleans and bounded integers only:
/// never paths, URLs, account, profile, model or content data, exception text
/// or stacks. Nothing here uploads, exports or sends logs anywhere.
library;

/// The process a snapshot describes. The background service and MCP clients
/// keep their own sessions in the same logs folder; their health is not part
/// of a desktop snapshot.
enum DiagnosticSupportHost { desktop }

/// Effective FORESIGHT_LOG_LEVEL of the session.
enum DiagnosticSupportLevel { error, warn, info, debug, trace, off }

/// The session's own derived health state, copied rather than inferred from
/// [DiagnosticSupportReason], plus [unavailable] when no session is attached.
enum DiagnosticSupportStatus {
  /// No logging session is attached, for example after a startup failure.
  unavailable,

  /// FORESIGHT_LOG_LEVEL=off: nothing is recorded.
  off,

  /// No authoritative report, or the last report is stale.
  unknown,

  /// Storage is configured and nothing has failed, but no log file slot has
  /// been admitted yet.
  starting,

  /// Storage is configured, nothing has failed and a log file slot is held.
  /// This is not a promise of durable storage.
  healthy,

  /// Enabled without configured storage, or the session reports a failure.
  degraded,

  /// Close has begun.
  closing,

  /// Close completed. This does not assert that the writer process exited.
  closed,
}

/// Closed health reasons of the logging session, plus [unavailable] when no
/// session is attached. A reason alone never implies a status.
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
  storageWorkerUnknown,
}

/// Closed health of diagnostics from the application's native library,
/// reported separately from the session [DiagnosticSupportStatus].
enum DiagnosticSupportNativeReason {
  unconfigured,
  healthy,
  unsupported,
  capacity,
  protocolFailed,
  unsettled,
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

  /// The folder or profile is a link, not a directory, not owned by this
  /// user or accessible to others; it was not revealed.
  unsafe,

  /// The local platform opener failed.
  failed,
}

const _maximumCounter = 0x7fffffff, _maximumSlot = 9;
int _bounded(int value) => value.clamp(0, _maximumCounter);

/// An immutable copy of the session's health snapshot and effective
/// configuration.
final class DiagnosticSupportSnapshot {
  DiagnosticSupportSnapshot({
    required this.status,
    required this.reason,
    this.host = DiagnosticSupportHost.desktop,
    this.level = DiagnosticSupportLevel.off,
    this.invalidLevel = false,
    this.transportTrace = false,
    this.storageConfigured = false,
    this.known = false,
    this.stale = false,
    int? ageMs,
    this.nativeReason = DiagnosticSupportNativeReason.unconfigured,
    this.nativeDropsExact = false,
    int admitted = 0,
    int dropped = 0,
    int rejected = 0,
    int highWaterBytes = 0,
    int highWaterRecords = 0,
    int refusedProducers = 0,
    int quarantinedProducers = 0,
    int? slot,
    this.logsFolderKnown = false,
  }) : ageMs = ageMs == null ? null : _bounded(ageMs),
       admitted = _bounded(admitted),
       dropped = _bounded(dropped),
       rejected = _bounded(rejected),
       highWaterBytes = _bounded(highWaterBytes),
       highWaterRecords = _bounded(highWaterRecords),
       refusedProducers = _bounded(refusedProducers),
       quarantinedProducers = _bounded(quarantinedProducers),
       slot = slot != null && slot >= 0 && slot <= _maximumSlot ? slot : null;

  const DiagnosticSupportSnapshot._unavailable()
    : status = DiagnosticSupportStatus.unavailable,
      reason = DiagnosticSupportReason.unavailable,
      host = DiagnosticSupportHost.desktop,
      level = DiagnosticSupportLevel.off,
      invalidLevel = false,
      transportTrace = false,
      storageConfigured = false,
      known = false,
      stale = false,
      ageMs = null,
      nativeReason = DiagnosticSupportNativeReason.unconfigured,
      nativeDropsExact = false,
      admitted = 0,
      dropped = 0,
      rejected = 0,
      highWaterBytes = 0,
      highWaterRecords = 0,
      refusedProducers = 0,
      quarantinedProducers = 0,
      slot = null,
      logsFolderKnown = false;

  static const unavailable = DiagnosticSupportSnapshot._unavailable();

  final DiagnosticSupportStatus status;
  final DiagnosticSupportReason reason;
  final DiagnosticSupportHost host;
  final DiagnosticSupportLevel level;
  final bool invalidLevel, transportTrace;

  /// A storage backend was configured for the session. It does not mean the
  /// platform or file system supports logging, or that anything was written.
  final bool storageConfigured;

  /// [known] is false until an authoritative report exists; a [stale] report
  /// keeps its last reason and counters but has status [unknown].
  final bool known, stale;

  /// Age of the report in milliseconds; null before any report.
  final int? ageMs;

  final DiagnosticSupportNativeReason nativeReason;
  final bool nativeDropsExact;

  /// Saturating session counters.
  final int admitted, dropped, rejected, highWaterBytes, highWaterRecords;
  final int refusedProducers, quarantinedProducers;

  /// Admitted log file slot, 0..9; null when none is held.
  final int? slot;

  /// Whether this session knows its selected profile's logs folder. It does
  /// not claim that the folder exists.
  final bool logsFolderKnown;

  /// Plain text a user may review and paste into a bug report. It contains
  /// only the closed fields above.
  String get supportText => [
    'host: ${host.name}',
    'status: ${status.name}',
    'reason: ${reason.name}',
    'level: ${level.name}',
    'invalid_level: $invalidLevel',
    'transport_trace: $transportTrace',
    'storage_configured: $storageConfigured',
    'known: $known',
    'stale: $stale',
    'age_ms: ${ageMs ?? 'none'}',
    'slot: ${slot ?? 'none'}',
    'native_reason: ${nativeReason.name}',
    'native_drops_exact: $nativeDropsExact',
    'admitted: $admitted',
    'dropped: $dropped',
    'rejected: $rejected',
    'high_water_bytes: $highWaterBytes',
    'high_water_records: $highWaterRecords',
    'producer_registration_refused: $refusedProducers',
    'producer_quarantined: $quarantinedProducers',
    'logs_folder_known: $logsFolderKnown',
  ].join('\n');
}

/// Supplied to desktop features at startup.
abstract interface class DiagnosticSupportPort {
  /// Copies the session's current health snapshot. Performs no I/O, allocates
  /// or registers no diagnostic producer and starts no port, timer or request.
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
