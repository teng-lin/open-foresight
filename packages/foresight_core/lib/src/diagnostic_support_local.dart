/// Startup-only adapter behind [DiagnosticSupportPort]. Only the application
/// entrypoint constructs it; features receive the port, never the session,
/// profile or path.
library;

import 'dart:io';

import 'diagnostic_support.dart';
import 'diagnostics/session.dart';
import 'platform_services.dart' show openPlatformUri;
import 'profile_paths.dart';

/// Reads the attached process [LoggingSession]'s in-memory health and reveals
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
    final health = session.health, configuration = session.configuration;
    return DiagnosticSupportSnapshot(
      reason: _reason(health.reason),
      level: _level(configuration.level),
      invalidLevel: configuration.invalidLevel,
      transportTrace: configuration.transportTrace,
      closed: health.closed,
      logsFolderKnown: _profile != null,
      admitted: health.admitted,
      dropped: health.dropped,
      rejected: health.rejected,
      refusedProducers: health.producerRegistrationRefused,
      quarantinedProducers: health.quarantinedProducers,
    );
  }

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

  /// The logs folder must be a real directory without group or other access,
  /// inside a profile directory that is not group/other writable, with no
  /// symbolic link anywhere in its canonical path. FileStat exposes no owner,
  /// so ownership relies on the storage worker's private creation inside the
  /// user's profile.
  static DiagnosticFolderOpenResult? _validate(String profile, String logs) {
    try {
      for (final (path, forbidden) in [(profile, 0x12), (logs, 0x3f)]) {
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          return DiagnosticFolderOpenResult.missing;
        }
        if (type != FileSystemEntityType.directory) {
          return DiagnosticFolderOpenResult.unsafe;
        }
        if (FileStat.statSync(path).mode & forbidden != 0) {
          return DiagnosticFolderOpenResult.unsafe;
        }
      }
      if (Directory(logs).resolveSymbolicLinksSync() != logs) {
        return DiagnosticFolderOpenResult.unsafe;
      }
    } on FileSystemException {
      return DiagnosticFolderOpenResult.unsafe;
    }
    return null;
  }

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
