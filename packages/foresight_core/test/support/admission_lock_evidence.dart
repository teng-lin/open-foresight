import 'dart:io';

import 'package:foresight_core/src/persistence/backup_files.dart';

/// What a fresh probe of a profile's `logs/admission.lock` observed.
enum AdmissionLockProbe {
  /// The probe acquired the lock, so no description held it at probe time.
  free,

  /// The kernel refused with EWOULDBLOCK/EAGAIN: another open description
  /// (possibly an inherited, not yet closed one) holds the lock.
  held,

  /// The checked lease refused: a closed file, or any errno other than
  /// EWOULDBLOCK/EAGAIN. Tests cover only the closed-file case; the errno path
  /// is not exercised (see the known gap in docs/testing.md).
  refused,

  /// The lock file or directory could not be opened for the probe.
  unopenable,
}

/// Probe the admission lock with a descriptor of its own, using the checked
/// lease so contention is told apart from any other errno. The result describes
/// the lock at probe time only. It does not say who held it earlier, so a
/// `retry` that happened before the probe stays unexplained when this is
/// [AdmissionLockProbe.free].
AdmissionLockProbe probeAdmissionLock(String profilePath) {
  BackupDirectory? logs;
  BackupFile? lock;
  try {
    logs = BackupDirectory('$profilePath/logs', create: false);
    lock = logs.open('admission.lock');
  } catch (_) {
    lock?.close();
    logs?.close();
    return AdmissionLockProbe.unopenable;
  }
  try {
    return probeLease(lock);
  } finally {
    lock.close();
    logs.close();
  }
}

/// Classify one checked non-blocking lease attempt on [lock]. A success takes
/// the lock; the caller closes the file to release it.
AdmissionLockProbe probeLease(BackupFile lock) {
  try {
    return lock.tryExclusiveLeaseChecked()
        ? AdmissionLockProbe.free
        : AdmissionLockProbe.held;
  } catch (_) {
    return AdmissionLockProbe.refused;
  }
}

/// Descriptors this OS process still has open on [profilePath]'s
/// `logs/admission.lock`, from `/proc/self/fd`; null where that is unavailable
/// (macOS). The count covers every isolate of the process, since `dart test`
/// runs suites as isolates of one process, and it matches this profile's exact
/// canonical path so other suites' lock files are not counted. Only this
/// process is inspected. Other processes' descriptors are never read.
int? ownAdmissionDescriptors(String profilePath) {
  final directory = Directory('/proc/self/fd');
  if (!directory.existsSync()) return null;
  final String target;
  try {
    target = File(
      '$profilePath/logs/admission.lock',
    ).resolveSymbolicLinksSync();
  } on FileSystemException {
    return 0;
  }
  var count = 0;
  try {
    for (final entry in directory.listSync(followLinks: false)) {
      try {
        if (Link(entry.path).targetSync() == target) count++;
      } on FileSystemException {
        // The listing's own descriptor can close before it is read.
      }
    }
  } on FileSystemException {
    return null;
  }
  return count;
}

/// One-line failure evidence for an unexpected admission `retry`.
String admissionLockEvidence(String profilePath) {
  final probe = probeAdmissionLock(profilePath);
  final own = ownAdmissionDescriptors(profilePath);
  final meaning = switch (probe) {
    AdmissionLockProbe.free => 'acquired by the probe; no holder at probe time',
    AdmissionLockProbe.held =>
      'kernel EWOULDBLOCK confirmed; another open description holds it',
    AdmissionLockProbe.refused => 'probe refused for a non-contention reason',
    AdmissionLockProbe.unopenable => 'lock file could not be opened',
  };
  return 'admission.lock post-failure probe: ${probe.name} - $meaning; '
      'open descriptors in this process on it: ${own ?? 'unavailable on this platform'}';
}
