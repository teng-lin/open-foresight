import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'platform_services.dart';
import 'profile_paths.dart';
import 'service_socket.dart';
import 'service_gates.dart';
import 'service_diagnostics.dart';

/// Another profile's service serves the endpoint, or listens on a socket
/// this profile's service needs (SL-7).
class AnotherProfileServing extends StateError {
  AnotherProfileServing(super.message);
}

String _sharedRuntimeMessage(String endpoint, {int? pid}) =>
    "Another Open Foresight profile's service"
    "${pid == null ? '' : ' (pid $pid)'} serves $endpoint: both profiles use "
    'runtime ${File(endpoint).parent.path}. Give this profile its own '
    'FORESIGHT_RUNTIME, or unset it.';

/// Why [profile] refuses [endpoint], which another profile's service (pid
/// [pid]) serves. A valid endpoint record names that runtime ([fromRecord]),
/// or this profile shares it with the other.
String anotherProfileMessage(
  ProfilePaths profile,
  String endpoint, {
  required bool fromRecord,
  int? pid,
}) => fromRecord
    ? 'The endpoint record ${profile.data}/$serviceEndpointRecordName names '
          'runtime ${File(endpoint).parent.path}, where another Open '
          "Foresight profile's service${pid == null ? '' : ' (pid $pid)'} "
          "serves. Starting this profile's service replaces the record."
    : _sharedRuntimeMessage(endpoint, pid: pid);

/// A service released before profile identity answers where this
/// profile's owner would, and this profile's lock is held, but the lock's
/// holder cannot be read (/proc/locks or stat is unavailable) or seen (it
/// runs outside this pid namespace). Waiting cannot tell more.
class UnverifiableServiceOwner extends StateError {
  UnverifiableServiceOwner(int? pid)
    : super(
        'Cannot verify the running older Open Foresight service'
        '${pid == null ? '' : ' (pid $pid)'} for this profile; stop it '
        'with its own --stop, then retry.',
      );
}

/// Reads the pids that hold a lock file's POSIX write lock, or null if they
/// cannot be read. Tests replace it to model such a host.
Set<int>? Function(String lock) readPosixLockHolders = _posixLockHolders;

/// Whether [status], answered at [endpoint], comes from the service of a
/// profile other than [profile]. A service released before profile identity
/// reports none, and every released version holds its profile's lock (S4).
/// Such a service is accepted only while this profile's endpoint record
/// still leads to [endpoint], because a new owner claims the record as soon
/// as it takes the lock. On Linux its status pid must also hold this
/// profile's lock; when the holder cannot be read or seen while the lock is
/// held and the record still leads here, this throws
/// [UnverifiableServiceOwner].
/// macOS has no /proc/locks, so there any holder counts: a service of
/// another profile that shares an explicit FORESIGHT_RUNTIME could pass
/// while this profile's new owner is starting.
///
/// The macOS check, and the Linux one when the holders cannot be read,
/// probe the lock. Never call this from a process that hosts an owner of
/// [profile]: POSIX record locks belong to the process, so closing the
/// probe's descriptor drops the owner's lock. [_localServiceOwners] skips
/// the probe only in the isolate that started that owner.
bool servesAnotherProfile(
  Map<Object?, Object?> status,
  ProfilePaths profile,
  String endpoint,
) {
  final owner = status['profile_id'];
  if (owner != null) return owner != profile.identity;
  // An owner in this process is current, so it reports its profile.
  if (hasLocalServiceOwner(canonicalProfilePath(profile.data))) {
    return true;
  }
  final lock = '${profile.data}/.application.lock';
  if (FileSystemEntity.typeSync(lock, followLinks: false) !=
      FileSystemEntityType.file) {
    return true;
  }
  if (Platform.isLinux) {
    final holders = readPosixLockHolders(lock);
    final pid = status['pid'];
    // No listed holder, or pid 0, is a holder this pid namespace cannot see,
    // unless nothing holds the lock at all.
    if (holders == null || holders.isEmpty || holders.contains(0)) {
      // No owner of this profile runs, or the lock holder claimed the
      // record away from here: either way this service is not its owner.
      if (serviceProfileLockFree(lock) ||
          serviceEndpoint(profile) != endpoint) {
        return true;
      }
      // Polling to the startup deadline would only blame another profile.
      throw UnverifiableServiceOwner(pid is int ? pid : null);
    }
    if (pid is! int || !holders.contains(pid)) return true;
  } else if (serviceProfileLockFree(lock)) {
    return true;
  }
  // The lock was held when checked; a new owner that holds it claims the
  // record at once, so a record that still leads here is its holder's.
  return serviceEndpoint(profile) != endpoint;
}

/// The pids holding a POSIX write lock on [lock], from /proc/locks, or null
/// if that cannot be read. Only the inode is compared, because btrfs
/// reports a subvolume's device to stat (0:31, 0:58) but the file system's
/// (00:1d) in /proc/locks. That fails open only if the same pid also locks a
/// file with this inode in another subvolume, which is very unlikely. The
/// kernel leaves out a holder this pid namespace cannot see, such as one
/// outside a flatpak sandbox; callers treat a holder listed as pid 0 the
/// same. A holder inside another pid namespace has another pid there than
/// here, and the check fails closed.
Set<int>? _posixLockHolders(String lock) {
  final ProcessResult stat;
  try {
    stat = Process.runSync('/usr/bin/stat', ['-c', '%i', lock]);
  } on ProcessException {
    return null;
  }
  final inode = int.tryParse(stat.stdout.toString().trim());
  if (stat.exitCode != 0 || inode == null) return null;
  final String table;
  try {
    table = File('/proc/locks').readAsStringSync();
  } on FileSystemException {
    return null;
  }
  final holders = <int>{};
  for (final line in const LineSplitter().convert(table)) {
    // "1: POSIX  ADVISORY  WRITE 4242 00:1d:2173873 0 EOF"; a blocked waiter
    // has "->" after its index and is skipped.
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 8 || fields[1] != 'POSIX' || fields[3] != 'WRITE') {
      continue;
    }
    final file = fields[5].split(':');
    final pid = int.tryParse(fields[4]);
    if (pid != null && file.length == 3 && int.tryParse(file[2]) == inode) {
      holders.add(pid);
    }
  }
  return holders;
}

// POSIX locks belong to the OS process, not a Dart isolate or file handle.
// Local hosts must finish before a launcher probes its own process's lock.
// Like every top-level variable, this is per isolate: it guards only probes
// made in the isolate that started the owner.
final _localServiceOwners = <String, int>{};
void Function() retainLocalServiceOwner(String data) {
  privateDirectory(data, repairOwnedPermissions: true);
  final key = Directory(data).resolveSymbolicLinksSync();
  _localServiceOwners[key] = (_localServiceOwners[key] ?? 0) + 1;
  var released = false;
  return () {
    if (released) return;
    released = true;
    final count = _localServiceOwners[key]!;
    if (count == 1) {
      _localServiceOwners.remove(key);
    } else {
      _localServiceOwners[key] = count - 1;
    }
  };
}

/// Why an owner must not take [inUse]'s path: another profile's service
/// listens there, or a connect could not tell (SL-7).
StateError _socketPathRefusal(SocketPathInUse inUse) => inUse.live
    ? AnotherProfileServing(_sharedRuntimeMessage(inUse.path))
    : StateError('$inUse; it was not removed.');

/// Clear [path] before an owner binds there. The caller holds its profile
/// lock, so the owner that left a socket there is gone, unless it is the
/// owner of another profile sharing this runtime directory. Only a socket
/// nobody listens on is deleted; report anything else instead (SL-7).
Future<void> clearStaleServiceSocket(String path) async {
  try {
    await clearStaleSocket(path);
  } on SocketPathInUse catch (inUse) {
    throw _socketPathRefusal(inUse);
  }
}

/// Why another service's socket keeps an owner out of [runtime], or null.
Future<SocketPathInUse?> serviceRuntimeInUse(String runtime) async {
  for (final name in ['application.sock', 'worker.sock']) {
    final inUse = await probeSocketPath('$runtime/$name');
    if (inUse != null) return inUse;
  }
  return null;
}

/// Publish [binding] without replacing a socket another owner published at
/// its path meanwhile (S2).
Future<void> publishServiceSocket(
  ServiceSocketBinding binding,
  void Function(Socket) onClient,
) async {
  try {
    await binding.publish(onClient);
  } on SocketPathInUse catch (inUse) {
    throw _socketPathRefusal(inUse);
  }
}

/// What a profile's endpoint record says. Reading never fails on its content:
/// an unusable record must not stop clients or a replacement owner.
sealed class EndpointRecord {
  const EndpointRecord();
}

final class EndpointAbsent extends EndpointRecord {
  const EndpointAbsent();
}

final class EndpointValid extends EndpointRecord {
  final String runtime;
  const EndpointValid(this.runtime);
}

final class EndpointInvalid extends EndpointRecord {
  /// A clause such as "it is not valid JSON (...)", for diagnostics.
  final String reason;
  const EndpointInvalid(this.reason);
}

const serviceEndpointRecordName = '.application-endpoint.json';
final serviceEndpointTemporary = RegExp(r'^\.application-endpoint\.json\.\d+$');
final _endpointQuarantine = RegExp(
  r'^\.application-endpoint\.json\.invalid-(\d+)$',
);

/// The profile lock is independent of runtime overrides. An endpoint record lets
/// clients attach to that owner even when launched with a different runtime.
EndpointRecord readEndpointRecord(ProfilePaths profile) =>
    readServiceEndpointRecordAt(
      profile,
      '${profile.data}/$serviceEndpointRecordName',
    );

EndpointRecord readServiceEndpointRecordAt(ProfilePaths profile, String path) {
  privateDirectory(profile.data, repairOwnedPermissions: true);
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return const EndpointAbsent();
  if (type == FileSystemEntityType.link) {
    return const EndpointInvalid('it is a symbolic link');
  }
  if (type != FileSystemEntityType.file) {
    return EndpointInvalid('it is a $type, not a file');
  }
  final Object? value;
  try {
    value = jsonDecode(File(path).readAsStringSync());
  } on PathNotFoundException {
    // A closing owner may remove its record between the type check and read.
    return const EndpointAbsent();
  } on FileSystemException catch (error) {
    return EndpointInvalid(
      'it cannot be read (${error.osError?.message ?? error.message})',
    );
  } on FormatException catch (error) {
    return EndpointInvalid('it is not valid JSON (${error.message})');
  }
  if (value is! Map ||
      value['data'] is! String ||
      value['runtime'] is! String) {
    return const EndpointInvalid(
      'it is not an object with string data and runtime fields',
    );
  }
  if (value['data'] != profile.data) {
    return EndpointInvalid('it names another profile (${value['data']})');
  }
  final runtime = value['runtime'] as String;
  if (!runtime.startsWith('/')) {
    return EndpointInvalid('its runtime is not an absolute path ($runtime)');
  }
  // dart:io would truncate the path at the NUL and use another directory.
  if (runtime.contains('\u0000')) {
    return const EndpointInvalid('its runtime contains a NUL character');
  }
  try {
    privateDirectory(runtime);
  } on StateError catch (error) {
    return EndpointInvalid('its runtime is unusable (${error.message})');
  } on FileSystemException catch (error) {
    return EndpointInvalid(
      'its runtime is unusable (${error.message}: '
      '${error.osError?.message ?? error.path})',
    );
  }
  return EndpointValid(runtime);
}

/// Only a valid record redirects clients; otherwise they use their own runtime,
/// which must be private just as a recorded one must. Pass [record] to reuse
/// a record the caller has already read.
String serviceEndpoint(ProfilePaths profile, [EndpointRecord? record]) {
  if ((record ?? readEndpointRecord(profile)) case EndpointValid(
    :final runtime,
  )) {
    return '$runtime/application.sock';
  }
  privateRuntime(profile);
  return '${profile.runtime}/application.sock';
}

// Match the listed path's last segment, not its URI: a directory's URI ends
// with a separator.
String serviceEntryName(String path) =>
    path.substring(path.lastIndexOf('/') + 1);

List<String> serviceEndpointEntries(String data, RegExp name) => [
  for (final entry in Directory(data).listSync(followLinks: false))
    if (name.hasMatch(serviceEntryName(entry.path))) entry.path,
];

// Renaming or deleting a symbolic link acts on the link, never its target.
void renameServiceEndpointEntry(String path, String target) =>
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      FileSystemEntityType.directory => Directory(path).renameSync(target),
      FileSystemEntityType.link => Link(path).renameSync(target),
      _ => File(path).renameSync(target),
    };

void deleteServiceEndpointEntry(String path) {
  try {
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      case FileSystemEntityType.notFound:
        return;
      case FileSystemEntityType.directory:
        Directory(path).deleteSync(recursive: true);
      case FileSystemEntityType.link:
        Link(path).deleteSync();
      default:
        File(path).deleteSync();
    }
  } on FileSystemException catch (error) {
    // Leftovers are only clutter; they must not block a new owner.
    stderr.writeln('Endpoint record cleanup: $error');
  }
}

/// Under the profile lock, set the record at [from] aside for diagnosis and
/// keep the newest three, so the owner can publish its own record. [inUse]
/// says it was valid, but another service uses its runtime.
void quarantineServiceEndpointRecord(
  String data,
  String reason, {
  required String from,
  bool inUse = false,
}) {
  final record = '$data/$serviceEndpointRecordName';
  final target = '$record.invalid-${DateTime.now().millisecondsSinceEpoch}';
  renameServiceEndpointEntry(from, target);
  stderr.writeln(
    inUse
        ? 'Set aside the application endpoint record as $target (runtime in '
              'use): $reason.'
        : 'Moved an invalid application endpoint record to $target: $reason.',
  );
  // A stamp too long for an int is not one this code wrote; drop it first.
  int stamp(String path) =>
      int.tryParse(
        _endpointQuarantine.firstMatch(serviceEntryName(path))![1]!,
      ) ??
      0;
  final quarantined = serviceEndpointEntries(data, _endpointQuarantine)
    ..sort((a, b) => stamp(a).compareTo(stamp(b)));
  for (final old in quarantined.take(max(0, quarantined.length - 3))) {
    deleteServiceEndpointEntry(old);
  }
}

/// Under the profile lock, take the predecessor's endpoint record out of
/// clients' sight at once, before this owner decides whether to adopt it, so
/// that no client reaches the runtime it names meanwhile (S4). An owner that
/// crashed while starting can leave a claimed record; it stays claimed unless
/// a newer record replaced it. Returns the claimed record's path.
String claimServiceEndpointRecord(String data) {
  final record = '$data/$serviceEndpointRecordName';
  final claimed = '$record.claimed';
  if (FileSystemEntity.typeSync(record, followLinks: false) !=
      FileSystemEntityType.notFound) {
    deleteServiceEndpointEntry(claimed);
    renameServiceEndpointEntry(record, claimed);
  }
  return claimed;
}

/// Whether a failed lockSync means another process holds the lock. F_SETLK
/// may report contention as EACCES or EAGAIN/EWOULDBLOCK (35 on macOS).
bool serviceLockContended(FileSystemException error) =>
    const {11, 13, 35}.contains(error.osError?.errorCode);

/// Whether no other process holds the profile lock at [path]. Only call this
/// from a process that hosts no owner of the profile: POSIX record locks
/// belong to the process, and closing this probe's descriptor drops them all.
/// Callers that check [_localServiceOwners] first are safe only in the
/// isolate that started the owner; another isolate does not see it there.
bool serviceProfileLockFree(String path) {
  // Keep this probe synchronous: opening and closing another descriptor must
  // not interleave with a local owner.
  final ownership = File(path).openSync(mode: FileMode.append);
  try {
    ownership.lockSync(FileLock.exclusive);
    return true;
  } on FileSystemException catch (error) {
    // This catch only covers lockSync; opening an inaccessible file still
    // fails.
    if (serviceLockContended(error)) return false;
    rethrow;
  } finally {
    ownership.closeSync();
  }
}

/// Another process holds the profile lock, so this owner did not start.
class ServiceOwnershipContended extends StateError {
  ServiceOwnershipContended(super.message);
}

/// The launcher that started this service stopped waiting for it before it
/// took the profile lock, so it does not serve.
class ServiceLaunchWithdrawn extends StateError {
  ServiceLaunchWithdrawn(super.message);
}

/// Callers pass a canonical profile path; no lock probe occurs here.
bool hasLocalServiceOwner(String canonicalData) =>
    _localServiceOwners.containsKey(canonicalData);

/// The configuration a service uses once it owns [profile]. Native
/// installations add profile-owned cache defaults; explicit values win.
RuntimeConfiguration profileServiceConfiguration(
  ProfilePaths profile,
  RuntimeConfiguration configuration,
) => configuration['FORESIGHT_NATIVE'] != null
    ? configuration.withProfileRuntime(profile.data)
    : configuration;

/// One non-waiting profile lock attempt, before worker resources are opened.
Future<RandomAccessFile> acquireServiceProfileLock(
  ProfilePaths profile, {
  required bool Function() launchWithdrawn,
  RuntimeConfiguration? configuration,
}) async {
  privateDirectory(profile.data, repairOwnedPermissions: true);
  // Configure native state only when a native installation is present. Tests
  // and administration may use the storage-only service without model workers.
  // Without a snapshot the legacy boundary receives the profile defaults.
  if (runtimeSnapshot(configuration)['FORESIGHT_NATIVE'] != null) {
    configureProfileRuntime(profile.data, configuration: configuration);
  }
  privateRuntime(profile);
  final lock = File(
    '${profile.data}/.application.lock',
  ).openSync(mode: FileMode.append);
  try {
    if (Process.runSync('/bin/chmod', [
          '600',
          '${profile.data}/.application.lock',
        ]).exitCode !=
        0) {
      throw StateError('Cannot protect profile ownership lock');
    }
    if (serviceGatesEnabled) await serviceGate('start.before_lock');
    // One attempt only. A start that lost the lock must never take it
    // later: the owner it lost to may exit in between, and nobody asked
    // this start to serve then. Its launcher decides whether to relaunch.
    try {
      lock.lockSync(FileLock.exclusive);
    } on FileSystemException catch (error) {
      if (!serviceLockContended(error)) rethrow;
      if (serviceGatesEnabled) await serviceGate('start.lock_contended');
      throw ServiceOwnershipContended(
        'Another application service owns this profile: $error',
      );
    }
    // A launch that reached the lock only after its launcher stopped
    // waiting (it attached to another owner, or gave up) serves nobody.
    if (launchWithdrawn()) {
      traceServiceTransport(() => 'launch lease withdrawn; not serving');
      throw ServiceLaunchWithdrawn(
        'The launcher that started this service stopped waiting for it, so '
        'it exits without serving.',
      );
    }
  } catch (_) {
    lock.closeSync();
    rethrow;
  }
  return lock;
}

/// Adopt a predecessor only after ruling out another profile's live runtime.
Future<({ProfilePaths profile, bool adopted})> adoptServiceProfileRuntime(
  ProfilePaths profile,
  String claimed,
) async {
  var adopted = false;
  switch (readServiceEndpointRecordAt(profile, claimed)) {
    case EndpointValid(:final runtime):
      // Another profile's service may use that runtime by now, for
      // example one sharing it; then this profile starts in its own (S1).
      final inUse = await serviceRuntimeInUse(runtime);
      if (inUse != null) {
        quarantineServiceEndpointRecord(
          profile.data,
          "another profile's service uses it ($inUse)",
          from: claimed,
          inUse: true,
        );
        break;
      }
      adopted = true;
      stderr.writeln(
        'Application service: the previous owner left its endpoint '
        'record; adopting its runtime.',
      );
      profile = ProfilePaths(profile.data, runtime);
    case EndpointInvalid(:final reason):
      quarantineServiceEndpointRecord(profile.data, reason, from: claimed);
    case EndpointAbsent():
      break;
  }
  return (profile: profile, adopted: adopted);
}
