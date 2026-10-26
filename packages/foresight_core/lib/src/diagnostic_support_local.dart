/// Startup-only adapter behind [DiagnosticSupportPort]. Only the application
/// entrypoint constructs it; features receive the port, never the session,
/// profile or path.
library;

import 'dart:io';

import 'diagnostic_support.dart';
import 'diagnostics/session.dart';
import 'persistence/backup_files.dart' show BackupDirectory;
import 'platform_services.dart' show openPlatformUri;
import 'profile_paths.dart';

/// Copies the attached process [LoggingSession]'s health snapshot and reveals
/// the canonical selected profile's `logs` folder through an injected local
/// URI opener. Attach the session and select the profile once each; later
/// calls are ignored, as LoggingSession.selectProfile ignores them across
/// desktop Retry.
final class LocalDiagnosticSupport implements DiagnosticSupportPort {
  LocalDiagnosticSupport({required this.openUri});

  /// Binds the existing local platform opener, which reveals a folder in
  /// Finder or the freedesktop file manager.
  LocalDiagnosticSupport.platform() : openUri = openPlatformUri;

  final Future<void> Function(Uri) openUri;
  LoggingSession? _session;
  String? _profile;
  Future<DiagnosticFolderOpenResult>? _opening;

  void attachSession(LoggingSession session) => _session ??= session;

  void selectProfile(ProfilePaths profile) {
    if (_profile != null) return;
    final String data;
    try {
      data = canonicalProfilePath(profile.data);
    } on FileSystemException {
      return;
    }
    // Same bound as the session's profile selection.
    if (data.length <= 1 || data.length > 4096 || data.contains('\u0000')) {
      return;
    }
    _profile = data;
  }

  @override
  DiagnosticSupportSnapshot snapshot() {
    final session = _session;
    if (session == null) return DiagnosticSupportSnapshot.unavailable;
    return fromHealth(
      session.healthSnapshot,
      logsFolderKnown: _profile != null,
    );
  }

  /// Field-by-field copy of a session health snapshot. The status is the
  /// snapshot's own derived state; nothing is inferred from its reason.
  static DiagnosticSupportSnapshot fromHealth(
    DiagnosticHealthSnapshot health, {
    bool logsFolderKnown = false,
  }) => DiagnosticSupportSnapshot(
    status: _status(health.state),
    reason: _reason(health.reason),
    level: _level(health.level),
    invalidLevel: health.invalidLevel,
    transportTrace: health.transportTrace,
    storageConfigured: health.storageConfigured,
    known: health.known,
    stale: health.stale,
    ageMs: health.ageMs,
    nativeReason: _native(health.nativeReason),
    nativeDropsExact: health.nativeDropsExact,
    admitted: health.admittedRecords,
    dropped: health.droppedRecords,
    rejected: health.rejectedRecords,
    highWaterBytes: health.highWaterBytes,
    highWaterRecords: health.highWaterRecords,
    refusedProducers: health.producerRegistrationRefused,
    quarantinedProducers: health.quarantinedProducers,
    slot: health.slot,
    logsFolderKnown: logsFolderKnown,
  );

  /// Concurrent requests share one validation and opener invocation.
  @override
  Future<DiagnosticFolderOpenResult> openLogsFolder() =>
      _opening ??= _open().whenComplete(() => _opening = null);

  Future<DiagnosticFolderOpenResult> _open() async {
    final profile = _profile;
    if (profile == null) return DiagnosticFolderOpenResult.unavailable;
    final logs = '$profile/logs';
    final refused = _validate(profile, logs);
    if (refused != null) return refused;
    try {
      await openUri(Uri.file(logs));
    } catch (_) {
      // Opener errors can carry the path and vendor output; keep them closed.
      return DiagnosticFolderOpenResult.failed;
    }
    return DiagnosticFolderOpenResult.opened;
  }

  /// Uses the storage writer's own directory primitive: every component is
  /// opened without following links, and the profile and logs folder must be
  /// directories owned by the effective user. The profile must not be group or
  /// other writable and the logs folder must have no group or other access.
  /// The path is then handed to the opener, so a same-user process could still
  /// swap it between this check and the reveal.
  static DiagnosticFolderOpenResult? _validate(String profile, String logs) {
    for (final path in [profile, logs]) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return DiagnosticFolderOpenResult.missing;
      }
    }
    BackupDirectory? parent, child;
    try {
      parent = BackupDirectory(profile, create: false, private: false);
      child = parent.child('logs', create: false);
    } catch (_) {
      return DiagnosticFolderOpenResult.unsafe;
    } finally {
      child?.close();
      parent?.close();
    }
    return null;
  }

  static DiagnosticSupportStatus _status(DiagnosticHealthState state) =>
      switch (state) {
        DiagnosticHealthState.off => DiagnosticSupportStatus.off,
        DiagnosticHealthState.unknown => DiagnosticSupportStatus.unknown,
        DiagnosticHealthState.starting => DiagnosticSupportStatus.starting,
        DiagnosticHealthState.healthy => DiagnosticSupportStatus.healthy,
        DiagnosticHealthState.degraded => DiagnosticSupportStatus.degraded,
        DiagnosticHealthState.closing => DiagnosticSupportStatus.closing,
        DiagnosticHealthState.closed => DiagnosticSupportStatus.closed,
      };

  static DiagnosticSupportNativeReason _native(
    NativeDiagnosticHealth reason,
  ) => switch (reason) {
    NativeDiagnosticHealth.unconfigured =>
      DiagnosticSupportNativeReason.unconfigured,
    NativeDiagnosticHealth.healthy => DiagnosticSupportNativeReason.healthy,
    NativeDiagnosticHealth.unsupported =>
      DiagnosticSupportNativeReason.unsupported,
    NativeDiagnosticHealth.capacity => DiagnosticSupportNativeReason.capacity,
    NativeDiagnosticHealth.protocolFailed =>
      DiagnosticSupportNativeReason.protocolFailed,
    NativeDiagnosticHealth.unsettled => DiagnosticSupportNativeReason.unsettled,
  };

  static DiagnosticSupportLevel _level(DiagnosticLevel level) =>
      switch (level) {
        DiagnosticLevel.error => DiagnosticSupportLevel.error,
        DiagnosticLevel.warn => DiagnosticSupportLevel.warn,
        DiagnosticLevel.info => DiagnosticSupportLevel.info,
        DiagnosticLevel.debug => DiagnosticSupportLevel.debug,
        DiagnosticLevel.trace => DiagnosticSupportLevel.trace,
        DiagnosticLevel.off => DiagnosticSupportLevel.off,
      };

  static DiagnosticSupportReason _reason(DiagnosticHealthReason reason) =>
      switch (reason) {
        DiagnosticHealthReason.healthy => DiagnosticSupportReason.healthy,
        DiagnosticHealthReason.bootstrapOnly =>
          DiagnosticSupportReason.bootstrapOnly,
        DiagnosticHealthReason.off => DiagnosticSupportReason.off,
        DiagnosticHealthReason.storageUnavailable =>
          DiagnosticSupportReason.storageUnavailable,
        DiagnosticHealthReason.unsupportedFilesystem =>
          DiagnosticSupportReason.unsupportedFilesystem,
        DiagnosticHealthReason.sinkFailed => DiagnosticSupportReason.sinkFailed,
        DiagnosticHealthReason.writerFailed =>
          DiagnosticSupportReason.writerFailed,
        DiagnosticHealthReason.closed => DiagnosticSupportReason.closed,
        DiagnosticHealthReason.storageWorkerUnconfigured =>
          DiagnosticSupportReason.storageWorkerUnconfigured,
        DiagnosticHealthReason.storageStagingUnavailable =>
          DiagnosticSupportReason.storageStagingUnavailable,
        DiagnosticHealthReason.storagePlatformUnsupported =>
          DiagnosticSupportReason.storagePlatformUnsupported,
        DiagnosticHealthReason.storageDescriptorLimit =>
          DiagnosticSupportReason.storageDescriptorLimit,
        DiagnosticHealthReason.storageWorkerLaunchFailed =>
          DiagnosticSupportReason.storageWorkerLaunchFailed,
        DiagnosticHealthReason.storageWorkerProtocolFailed =>
          DiagnosticSupportReason.storageWorkerProtocolFailed,
        DiagnosticHealthReason.storageWorkerExited =>
          DiagnosticSupportReason.storageWorkerExited,
        DiagnosticHealthReason.storageWorkerUnresponsive =>
          DiagnosticSupportReason.storageWorkerUnresponsive,
        DiagnosticHealthReason.storageWorkerUnknown =>
          DiagnosticSupportReason.storageWorkerUnknown,
      };
}
