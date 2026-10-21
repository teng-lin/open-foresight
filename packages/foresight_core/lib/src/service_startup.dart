import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'operations.dart';
import 'profile_paths.dart';
import 'platform_services.dart';
import 'rpc_error.dart';
import 'service_client.dart';
import 'service_compatibility.dart';
import 'service_diagnostics.dart';
import 'service_ownership.dart';

/// Whether [path] names a startup status file in [profile]'s runtime.
bool _isStartupStatusPath(String path, ProfilePaths profile) =>
    _startupStatusName.hasMatch(serviceEntryName(path)) &&
    canonicalProfilePath(File(path).parent.path) == profile.runtime;

/// Whether this service's launcher has stopped waiting for it. The launcher
/// creates FORESIGHT_STARTUP_STATUS before launching and deletes it when it
/// returns, so a missing file is a withdrawn lease. A launcher attaches only
/// to the lock holder, so a launch that holds the lock while its lease is
/// still there is the owner its launcher waits for. Starts without a lease,
/// such as direct starts, are unaffected.
bool serviceLaunchLeaseWithdrawn(ProfilePaths profile) {
  final path = runtimeConfiguration['FORESIGHT_STARTUP_STATUS'];
  if (path == null || !_isStartupStatusPath(path, profile)) return false;
  return FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound;
}

class _ClosingService implements Exception {
  final ServiceClient client;
  _ClosingService(this.client);
}

typedef ServiceStartup = ({ServiceClient client, Map<String, dynamic> status});

/// The startup deadline ended a status probe of [endpoint] before its reply.
class _ProbeCutShort extends TimeoutException {
  _ProbeCutShort(this.endpoint)
    : super('Application service did not answer its startup status probe');
  final String endpoint;
}

/// The service of another profile answered at [endpoint] (SL-7), which a
/// valid endpoint record named ([fromRecord]) or this profile's runtime holds.
class _ForeignOwner implements Exception {
  final String endpoint;
  final int? pid;
  final bool fromRecord;
  _ForeignOwner(this.endpoint, this.pid, {required this.fromRecord});
}

String _describeDuration(Duration duration) =>
    duration.inMilliseconds % 1000 == 0
    ? '${duration.inSeconds} s'
    : '${duration.inMilliseconds} ms';

Future<ServiceStartup> _connectCompatibleService(
  ProfilePaths profile,
  String path,
  Duration Function() remaining,
  Duration statusProbeLimit, {
  required bool snapshot,
  required bool fromRecord,
  Set<String> refused = const {},
}) async {
  final left = remaining();
  final client = await ServiceClient.connect(
    path,
    connectTimeout: left < const Duration(seconds: 2)
        ? left
        : const Duration(seconds: 2),
  );
  Future<Map<String, dynamic>> status({bool desktop = false}) async {
    // A stalled owner must not hold startup for the whole budget (L1).
    final deadline = remaining();
    final capped = deadline > statusProbeLimit;
    final args = desktop
        ? <String, dynamic>{
            'desktop': true,
            'token': File(
              '${profile.data}/.desktop-capability',
            ).readAsStringSync(),
          }
        : const <String, dynamic>{};
    final reply = await client
        .call(Operation.status.wire, {
          ...args,
          applicationClientVersionField: applicationApiVersion,
        })
        .timeout(
          capped ? statusProbeLimit : deadline,
          onTimeout: () => throw capped
              ? TimeoutException(
                  'Application service at $path accepted the connection but '
                  'did not answer status within '
                  '${_describeDuration(statusProbeLimit)}; it may be busy '
                  'or hung.',
                )
              : _ProbeCutShort(path),
        );
    final value = parseApplicationStatus(reply);
    // Another profile's owner is never ours, whatever its version. The first
    // probe checks this before a desktop snapshot sends its capability. A
    // service without profile_id that this startup already refused stays
    // refused, even once this profile's own new owner holds the lock (S4).
    if (servesAnotherProfile(value, profile, path) ||
        (value['profile_id'] == null && refused.contains(path))) {
      final pid = value['pid'];
      throw _ForeignOwner(
        path,
        pid is int ? pid : null,
        fromRecord: fromRecord,
      );
    }
    validateApplicationApiVersion(value, endpoint: path);
    if (runtimeConfiguration['FORESIGHT_RUNTIME_REVISION'] != null) {
      validateServiceCompatibility(value);
    }
    return value;
  }

  try {
    // Even development launches must not hand a closing owner to the desktop.
    var initial = await status();
    // The desktop's final snapshot is part of startup, with the same deadline,
    // exact closing-error classification, and clean profile-owner handoff.
    if (snapshot) initial = await status(desktop: true);
    return (client: client, status: initial);
  } on RpcError catch (error) {
    // Status is read-only, so this means: wait for this owner, then hand off.
    if (closingOwnerEndedProbe(error)) {
      // Transfer ownership of this specific socket to the startup handoff.
      throw _ClosingService(client);
    }
    await client.close();
    rethrow;
  } catch (_) {
    await client.close();
    rethrow;
  }
}

/// Whether [error] ended a read-only status probe because its owner is
/// closing: the owner refused the probe, or ended it as it began closing.
/// A lost connection is not this owner's answer.
bool closingOwnerEndedProbe(RpcError error) =>
    isClosingRefusal(error) ||
    (error.code == RpcErrorCode.unavailable &&
        error.reason == RpcErrorReason.outcomeUnknown &&
        !isServiceTransportLost(error));

bool _profileOwnerAvailable(
  ProfilePaths profile, {
  required bool closingOwner,
}) {
  final key = Directory(profile.data).resolveSymbolicLinksSync();
  if (hasLocalServiceOwner(key)) return false;
  final path = '${profile.data}/.application.lock';
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (!closingOwner && type == FileSystemEntityType.notFound) return true;
  // A closing owner of this profile always leaves its lock file. If it is
  // missing, the closing owner may belong to another profile that shares this
  // runtime directory (SL-7). Its refusal carries no profile identity, which
  // only status reports, so refuse rather than launch beside it.
  if (closingOwner && type == FileSystemEntityType.notFound) {
    throw AnotherProfileServing(
      'The application service closing at this endpoint does not own this '
      "profile ($path is missing): another profile's service shares its "
      'runtime. Give this profile its own FORESIGHT_RUNTIME, or unset it.',
    );
  }
  if (type != FileSystemEntityType.file) {
    throw StateError(
      'Application service ownership lock is missing or unsafe: $path',
    );
  }
  if (!serviceProfileLockFree(path)) return false;
  // A record without a lock owner means the previous owner exited
  // uncleanly. The replacement adopts that record's runtime in _start, or
  // sets the record aside if it is invalid.
  if (FileSystemEntity.typeSync(
        '${profile.data}/.application-endpoint.json',
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound) {
    traceServiceTransport(
      () =>
          'previous owner left its endpoint record; the replacement adopts its runtime',
    );
  }
  return true;
}

/// Whether [pid] may still run. Without a way to tell, assume it does, so
/// only the profile lock decides.
Future<bool> _processRunning(int pid) async {
  if (Platform.isLinux && Directory('/proc/self').existsSync()) {
    return Directory('/proc/$pid').existsSync();
  }
  try {
    return (await Process.run('/bin/kill', ['-0', '$pid'])).exitCode == 0;
  } on ProcessException {
    return true;
  }
}

/// After `--stop` signalled the owner [ownerPid] and saw its connection close,
/// wait until the owner released the profile: its lock is free, or the
/// process is gone. EOF comes once the helper has stopped, but before the
/// owner closes its store, removes its sockets and endpoint record, and
/// releases the lock (L6). Without [ownerPid], as for an owner that refused
/// its status because it was already stopping, only the lock decides.
/// Returns false if neither happens within [timeout]. Never call this from a
/// process that hosts an owner of the profile, in any isolate: it probes the
/// lock, POSIX record locks belong to the process, and closing the probe's
/// descriptor drops the owner's lock.
Future<bool> awaitProfileRelease(
  ProfilePaths profile,
  int? ownerPid, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final waited = Stopwatch()..start();
  var held = false;
  while (true) {
    if ((ownerPid != null && !await _processRunning(ownerPid)) ||
        profileReleased(profile)) {
      return true;
    }
    if (!held) {
      held = true;
      traceServiceTransport(
        () =>
            'stop: service${ownerPid == null ? '' : ' $ownerPid'} still holds '
            'its profile',
      );
    }
    if (waited.elapsed >= timeout) return false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// [awaitProfileRelease], failing with a message when it times out.
Future<void> requireProfileRelease(
  ProfilePaths profile,
  int? ownerPid, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  if (!await awaitProfileRelease(profile, ownerPid, timeout: timeout)) {
    throw StateError(
      'The application service${ownerPid == null ? '' : ' (pid $ownerPid)'} '
      'closed its connections but did not release its profile within '
      '${_describeDuration(timeout)}.',
    );
  }
}

/// Whether no process holds [profile]'s lock: the lock file is missing or
/// free. Never call this from a process that hosts an owner of the profile,
/// in any isolate: it probes the lock, POSIX record locks belong to the
/// process, and closing the probe's descriptor drops the owner's lock.
bool profileReleased(ProfilePaths profile) {
  final lock = '${profile.data}/.application.lock';
  return FileSystemEntity.typeSync(lock, followLinks: false) ==
          FileSystemEntityType.notFound ||
      serviceProfileLockFree(lock);
}

/// Whether the profile has no owner but still has an endpoint record: the
/// last owner did not shut down cleanly, and the next one recovers its
/// runtime. Never call this from a process that hosts an owner of the
/// profile, in any isolate: it probes the lock, POSIX record locks belong to
/// the process, and closing the probe's descriptor drops the owner's lock.
bool profileLeftUnclean(ProfilePaths profile) =>
    FileSystemEntity.typeSync(
          '${profile.data}/$serviceEndpointRecordName',
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound &&
    profileReleased(profile);

/// Start packaged services as applications through LaunchServices so macOS can
/// attribute protected operations to the service bundle. Installed TCC attribution
/// still requires an integration check.
/// Forward profile/runtime overrides explicitly; an agent host's unrelated
/// environment must not become command-line arguments or service configuration.
({String executable, List<String> arguments}) serviceLaunchCommand(
  String executable,
  Map<String, String> environment, {
  bool? macOS,
  String? startupEnvironmentFile,
}) {
  if (macOS ?? Platform.isMacOS) {
    final canonical = File(executable).resolveSymbolicLinksSync();
    const executableMarker = '.app/Contents/MacOS/';
    final marker = canonical.lastIndexOf(executableMarker);
    if (marker >= 0 &&
        !canonical.substring(marker + executableMarker.length).contains('/')) {
      final bundle = canonical.substring(0, marker + 4);
      if (!File('$bundle/Contents/Info.plist').existsSync()) {
        throw StateError(
          'Application service bundle is missing Info.plist: $bundle',
        );
      }
      if (startupEnvironmentFile == null) {
        throw StateError('A private startup environment handoff is required');
      }
      return (
        executable: '/usr/bin/open',
        arguments: [
          '-g',
          '-n',
          '--env',
          'FORESIGHT_STARTUP_ENV=$startupEnvironmentFile',
          bundle,
        ],
      );
    }
  }
  return (executable: executable, arguments: const []);
}

/// Distribution credentials travel through a private file, never open --env argv.
Future<File> writeServiceStartupEnvironment(
  Directory runtime,
  Map<String, String> environment,
) async {
  privateDirectory(runtime.path);
  final directory = await createPrivateTempDirectory(runtime, 'of-launch-');
  final file = File('${directory.path}/startup.json');
  try {
    await file.writeAsString(
      jsonEncode({
        for (final entry in environment.entries)
          if ((entry.key.startsWith('FORESIGHT_') ||
                  entry.key == 'PYTHONPYCACHEPREFIX') &&
              entry.key != 'FORESIGHT_STARTUP_ENV')
            entry.key: entry.value,
      }),
      flush: true,
    );
    protectPrivateFile(file.path);
    return file;
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
}

final _startupStatusName = RegExp(r'^startup-[A-Za-z0-9_-]+\.json$');
// A status file, or the staging copy a service writes before renaming it.
final _startupStatusEntry = RegExp(r'^startup-[A-Za-z0-9_-]+\.json(\.\d+)?$');

/// Remove startup status files that no launcher still waits on: every
/// launcher gives up within three minutes, and a launch that lost the race
/// may write after its launcher returned. A live lease is never removed: it
/// is younger than its launcher's elapsed time, which is under three
/// minutes. A link is removed as a link; this code never writes one.
void _sweepStartupStatus(String runtime) {
  final cutoff = DateTime.now().subtract(const Duration(minutes: 3));
  for (final path in serviceEndpointEntries(runtime, _startupStatusEntry)) {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (type == FileSystemEntityType.file &&
              File(path).lastModifiedSync().isBefore(cutoff))) {
        deleteServiceEndpointEntry(path);
      }
    } on FileSystemException {
      // Another launcher removed it first.
    }
  }
}

/// Record why this service did not start, for the launcher waiting on it.
/// FORESIGHT_STARTUP_STATUS names the file; it must be a startup status in
/// [profile]'s runtime directory, and anything else is ignored. A start that
/// lost the profile lock records `contended`, never a failure: it did
/// nothing, and its launcher attaches to the owner or launches again.
void recordServiceStartupFailure(ProfilePaths profile, Object error) {
  final path = runtimeConfiguration['FORESIGHT_STARTUP_STATUS'];
  if (path == null) return;
  try {
    if (!_isStartupStatusPath(path, profile)) {
      stderr.writeln('Ignoring a startup status outside the runtime: $path');
      return;
    }
    // The status replaces the launcher's lease. With the lease gone, the
    // launcher has stopped waiting and nobody would read it.
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return;
    }
    final staging = File('$path.$pid')
      ..writeAsStringSync(
        jsonEncode(
          error is ServiceOwnershipContended
              ? {'state': 'contended'}
              : {
                  'state': 'failed',
                  'error': error is StateError ? error.message : '$error',
                },
        ),
        flush: true,
      );
    protectPrivateFile(staging.path);
    staging.renameSync(path);
  } catch (failure) {
    stderr.writeln('Cannot record the startup failure: $failure');
  }
}

/// What a launched service recorded in its startup status.
sealed class _StartupOutcome {
  const _StartupOutcome();
}

/// It lost the profile lock before touching the profile.
final class _StartupContended extends _StartupOutcome {
  const _StartupContended();
}

final class _StartupFailed extends _StartupOutcome {
  final String cause;
  const _StartupFailed(this.cause);
}

/// The outcome a launched service recorded in [status], if any yet.
_StartupOutcome? _recordedStartupOutcome(File status) {
  try {
    final value = jsonDecode(status.readAsStringSync());
    if (value is Map && value['state'] == 'contended') {
      return const _StartupContended();
    }
    if (value is Map && value['state'] == 'failed') {
      return _StartupFailed('${value['error']}'.split('\n').first);
    }
  } on FileSystemException {
    // Not written: the service has not stopped, or not yet.
  } on FormatException {
    // Not a status this client understands.
  }
  return null;
}

// Launches by one ensureService call; only a launch that provably did
// nothing (it lost the profile lock) is followed by another.
const _maxLaunches = 3;

/// Attach first; competing launchers may race safely on the service's OS lock.
///
/// [statusProbeLimit] bounds each startup status probe; tests shorten it.
///
/// Deciding whether to launch probes the profile lock. Never call this from
/// a process that hosts an owner of [profile] in another isolate: POSIX
/// record locks belong to the process, so closing the probe's descriptor
/// drops the owner's lock. [_localServiceOwners] skips the probe only in the
/// isolate that started the owner.
Future<ServiceClient> ensureService(
  ProfilePaths profile, {
  Duration startupTimeout = const Duration(minutes: 3),
  Duration statusProbeLimit = const Duration(seconds: 30),
}) async => (await _ensureService(
  profile,
  startupTimeout: startupTimeout,
  statusProbeLimit: statusProbeLimit,
)).client;

/// Reserve desktop socket lifetime and obtain its final startup snapshot.
/// This does not grant the visible desktop's approval-host capability.
/// Closing/transport failures here use the original startup deadline and owner
/// handoff; no business operation is retried. The restriction of
/// [ensureService] on processes that host an owner applies.
Future<ServiceStartup> ensureServiceSnapshot(
  ProfilePaths profile, {
  Duration startupTimeout = const Duration(minutes: 3),
  Duration statusProbeLimit = const Duration(seconds: 30),
}) => _ensureService(
  profile,
  startupTimeout: startupTimeout,
  statusProbeLimit: statusProbeLimit,
  snapshot: true,
);

Future<ServiceStartup> _ensureService(
  ProfilePaths profile, {
  required Duration startupTimeout,
  required Duration statusProbeLimit,
  bool snapshot = false,
}) async {
  if (startupTimeout <= Duration.zero ||
      startupTimeout > const Duration(minutes: 3)) {
    throw ArgumentError.value(startupTimeout, 'startupTimeout');
  }
  if (statusProbeLimit <= Duration.zero) {
    throw ArgumentError.value(statusProbeLimit, 'statusProbeLimit');
  }
  final startup = Stopwatch()..start();
  var closingOwner = false;
  var launches = 0;
  final launcher = _ServiceLaunchAttempt(profile);
  String? ignoredRecord;
  // Why this profile's endpoint record names another profile's service.
  String? staleRecord;
  // Endpoints whose service this startup found to be another profile's.
  final refused = <String>{};
  TimeoutException deadlineFailure() {
    final failure = launches > 0
        ? launcher.startupLog != null
              ? 'Application service did not start. Inspect ${launcher.startupLog}.'
              : 'Application service did not start. Run ${launcher.executable} directly to inspect the startup error.'
        : staleRecord ??
              (closingOwner
                  ? 'Application service owner handoff did not finish'
                  : 'Application service profile lock is still held; its owner is not serving the endpoint.');
    return TimeoutException(
      ignoredRecord == null
          ? failure
          : '${failure.endsWith('.') ? failure : '$failure.'} The endpoint '
                'record ${profile.data}/$serviceEndpointRecordName was ignored '
                'because $ignoredRecord.',
    );
  }

  Duration remaining() {
    final left = startupTimeout - startup.elapsed;
    if (left <= Duration.zero) throw deadlineFailure();
    return left;
  }

  try {
    while (true) {
      try {
        // An invalid record is treated as absent. Only an owner holding the
        // profile lock may move it aside.
        final record = readEndpointRecord(profile);
        ignoredRecord = record is EndpointInvalid ? record.reason : null;
        return await _connectCompatibleService(
          profile,
          serviceEndpoint(profile, record),
          remaining,
          statusProbeLimit,
          snapshot: snapshot,
          fromRecord: record is EndpointValid,
          refused: refused,
        );
      } on _ForeignOwner catch (owner) {
        refused.add(owner.endpoint);
        final message = anotherProfileMessage(
          profile,
          owner.endpoint,
          fromRecord: owner.fromRecord,
          pid: owner.pid,
        );
        traceServiceTransport(() => message);
        // A service that answers status is not closing, so waiting does not
        // make it go away, and this profile's service cannot start beside it
        // (Q3).
        if (!owner.fromRecord) throw AnotherProfileServing(message);
        // This profile's crashed owner left a record naming a runtime that
        // another profile's service now uses. Never attach there; once this
        // profile's lock is free, the launch below replaces the record (S1).
        staleRecord = message;
      } on _ProbeCutShort catch (cut) {
        // A probe of the stale record's endpoint that the deadline cut short
        // says nothing new about it. Any other probe, such as one of this
        // profile's slowly starting owner, keeps its own message.
        final stale = staleRecord;
        if (stale == null || !refused.contains(cut.endpoint)) rethrow;
        throw TimeoutException(stale);
      } on _ClosingService catch (closing) {
        closingOwner = true;
        try {
          // EOF alone precedes the worker's final profile-lock release.
          await closing.client.socket.done.timeout(
            remaining(),
            onTimeout: () => throw deadlineFailure(),
          );
        } finally {
          await closing.client.close();
        }
      } on RpcError catch (error) {
        if (!isServiceTransportLost(error)) rethrow;
        // An isolated frontend can accept while its worker is already gone.
        // Retry only this startup status probe, never a business operation.
      } on SocketException {
        // A starting or closing owner may still hold the profile lock.
      }
      remaining();
      if (launches == 0 &&
          _profileOwnerAvailable(profile, closingOwner: closingOwner)) {
        privateRuntime(profile);
        launches++;
        await launcher.launch();
      }
      switch (launcher.outcome) {
        // A replacement that died says why at once (L3), unless another
        // owner holds the profile and will answer instead.
        case _StartupFailed(:final cause)
            when _profileOwnerAvailable(profile, closingOwner: false):
          throw StateError('Application service failed to start: $cause');
        // The launch lost the lock before touching the profile, for example
        // to another launcher's or --stop's momentary probe. If nobody holds
        // it now, launch again; otherwise attach to the owner that does.
        case _StartupContended()
            when _profileOwnerAvailable(profile, closingOwner: false):
          if (launches >= _maxLaunches) {
            throw StateError(
              'Application service could not take the profile lock: another '
              'process kept holding it for each of $_maxLaunches launches.',
            );
          }
          await launcher.retire();
          launches++;
          await launcher.launch();
        default:
          break;
      }
      // This read-only startup loop can attach to a competing legitimate
      // owner. It never replays a business operation, and it launches again
      // only after a launch provably did nothing: it lost the profile lock.
      final left = remaining();
      await Future<void>.delayed(
        left < const Duration(milliseconds: 100)
            ? left
            : const Duration(milliseconds: 100),
      );
    }
  } finally {
    await launcher.retire();
  }
}

/// One launcher owns its temporary lease and private environment handoff.
/// The startup coordinator alone owns the shared deadline and retry decision.
final class _ServiceLaunchAttempt {
  _ServiceLaunchAttempt(this.profile);
  final ProfilePaths profile;
  String? executable;
  String? startupLog;
  File? handoff;
  // Where the latest launch records a start that did not happen.
  File? startupStatus;
  Future<void> launch() async {
    final serviceExecutable = runtimeConfiguration['FORESIGHT_SERVICE'];
    if (serviceExecutable == null || !File(serviceExecutable).existsSync()) {
      throw StateError(
        'Set FORESIGHT_SERVICE to the application-service executable',
      );
    }
    executable = serviceExecutable;
    _sweepStartupStatus(profile.runtime);
    final launchId = [
      pid,
      DateTime.now().microsecondsSinceEpoch,
      Random.secure().nextInt(1 << 32),
    ].join('-');
    startupStatus = File('${profile.runtime}/startup-$launchId.json');
    // This launch's lease. The service serves only if it still exists once
    // it holds the profile lock, and writes its outcome over it; deleting it
    // when this call returns withdraws the lease.
    startupStatus!.writeAsStringSync(
      jsonEncode({'state': 'launching'}),
      flush: true,
    );
    protectPrivateFile(startupStatus!.path);
    final environment = {
      ...runtimeConfiguration.environment,
      'FORESIGHT_DATA': profile.data,
      'FORESIGHT_RUNTIME': profile.runtime,
      // On macOS this travels through the private startup handoff.
      'FORESIGHT_STARTUP_STATUS': startupStatus!.path,
    };
    handoff = Platform.isMacOS
        ? await writeServiceStartupEnvironment(
            Directory(profile.runtime),
            environment,
          )
        : null;
    {
      final launch = serviceLaunchCommand(
        serviceExecutable,
        environment,
        startupEnvironmentFile: handoff?.path,
      );
      if (launch.executable == '/usr/bin/open') {
        final logPath = '${profile.runtime}/service-startup.log';
        startupLog = logPath;
        if (FileSystemEntity.typeSync(logPath, followLinks: false) ==
            FileSystemEntityType.link) {
          throw StateError(
            'Service startup log must not be a symbolic link: $startupLog',
          );
        }
        File(logPath).openSync(mode: FileMode.append).closeSync();
        final protect = await Process.run('/bin/chmod', ['600', logPath]);
        if (protect.exitCode != 0) {
          throw StateError('Cannot protect $startupLog');
        }
        launch.arguments.insertAll(2, ['--stderr', logPath]);
        final result = await Process.run(launch.executable, launch.arguments);
        if (result.exitCode != 0) {
          throw StateError(
            'LaunchServices could not start the application service: ${result.stderr}. See $startupLog.',
          );
        }
      } else {
        await Process.start(
          launch.executable,
          launch.arguments,
          mode: ProcessStartMode.detached,
          environment: environment,
        );
      }
    }
  }

  _StartupOutcome? get outcome =>
      startupStatus == null ? null : _recordedStartupOutcome(startupStatus!);
  Future<void> retire() => _deleteLaunchFiles(startupStatus, handoff);
}

/// Remove one launch's startup status and its unconsumed environment handoff.
Future<void> _deleteLaunchFiles(File? status, File? handoff) async {
  if (handoff != null && handoff.existsSync()) {
    await handoff.delete();
    await handoff.parent.delete();
  }
  if (status != null && status.existsSync()) await status.delete();
}
