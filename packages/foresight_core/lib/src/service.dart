import 'application.dart';
import 'rpc_error.dart';
import 'operations.dart';
import 'platform_services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math';
import 'agent_access.dart';
import 'domain.dart';
import 'web_search.dart';
import 'helper.dart';
import 'model_setup.dart';
import 'profile_paths.dart';
import 'store.dart';
import 'service_socket.dart';

const maxServiceMessage = 16 * 1024 * 1024;
// Clients up to v0.1.2 counted bytes per socket read, not per frame, so a
// frame at their limit followed by more bytes in the same read failed. Current
// clients count each frame exactly; keep frames 1 MiB under the limit for the
// released ones.
const _maxServiceFrame = maxServiceMessage - 1024 * 1024;
const _outcomeUnknownMessage =
    'Application service stopped before this request finished; it may or may '
    'not have completed.';
// The whole flush of closing connections, not each one.
const _closingFlushBound = Duration(seconds: 2);
// How long a retired connection waits for its owner's remaining answers. A
// closing owner sends them all before its first await, then flushes them
// within its flush bound; the margin covers scheduling under load.
const _retiredConnectionGrace = Duration(seconds: 5);

Future<void> _flushQuietly(Socket socket) async {
  try {
    await socket.flush();
  } catch (_) {
    // The peer has gone; nothing is left to deliver.
  }
}

/// The refusal a closing owner sends for a request it did not dispatch.
RpcError _closingRefusal() => RpcError(
  RpcErrorCode.unavailable,
  serviceClosingMessage,
  reason: RpcErrorReason.closing,
);

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
    ? 'The endpoint record ${profile.data}/$_endpointRecordName names '
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
  if (_localServiceOwners.containsKey(canonicalProfilePath(profile.data))) {
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
    // Pid 0 is a holder this pid namespace cannot see.
    if (holders == null || holders.contains(0)) {
      // No owner of this profile runs, or the lock holder claimed the
      // record away from here: either way this service is not its owner.
      if (_profileLockFree(lock) || serviceEndpoint(profile) != endpoint) {
        return true;
      }
      // Polling to the startup deadline would only blame another profile.
      throw UnverifiableServiceOwner(pid is int ? pid : null);
    }
    if (pid is! int || !holders.contains(pid)) return true;
  } else if (_profileLockFree(lock)) {
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
/// file with this inode in another subvolume, which is very unlikely. A
/// holder this pid namespace cannot see, such as one outside a flatpak
/// sandbox, is listed as pid 0. A holder inside another pid namespace has
/// another pid there than here, and the check fails closed.
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
void Function() _retainLocalServiceOwner(String data) {
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

void _traceServiceTransport(String message) {
  if (runtimeConfiguration['FORESIGHT_SERVICE_TRACE'] == '1') {
    final bounded = message.length > 16384
        ? message.substring(0, 16384)
        : message;
    stderr.writeln(
      'Service transport $pid ${DateTime.now().toIso8601String()} $bounded',
    );
  }
}

/// Whether lifecycle gates are active. Only a build compiled with
/// -DFORESIGHT_ENABLE_TEST_HOOKS=true keeps FORESIGHT_SERVICE_GATES in its
/// runtime configuration. Callers check this before awaiting [serviceGate],
/// so production code gains no await at a gate point.
bool get serviceGatesEnabled =>
    runtimeConfiguration['FORESIGHT_SERVICE_GATES'] != null;

final _serviceGateNames = RegExp(r'^[A-Za-z0-9_.-]+$');

/// A named point where lifecycle tests can hold the service, in both the
/// frontend and the worker isolate. With FORESIGHT_SERVICE_GATES naming a
/// directory, it publishes `<point>.reached` (this pid) there. If the test
/// armed the point with `<point>.hold`, it then waits for `<point>.release`
/// or `release-all`. Polling only delays a release; the test decides the
/// order. A `<point>.crash` file instead makes the calling isolate fail with
/// an uncaught error, as a fatal fault would, without any cleanup. Without
/// the key it returns at once.
Future<void> serviceGate(String point) async {
  final directory = runtimeConfiguration['FORESIGHT_SERVICE_GATES'];
  if (directory == null) return;
  if (!_serviceGateNames.hasMatch(point)) {
    throw ArgumentError.value(point, 'point');
  }
  try {
    final staging = File('$directory/.$point.$pid.${Random().nextInt(1 << 32)}')
      ..writeAsStringSync('$pid', flush: true);
    staging.renameSync('$directory/$point.reached');
    if (File('$directory/$point.crash').existsSync()) {
      _traceServiceTransport('gate crash $point');
      // The root zone is outside the worker's guarded zone, so the isolate
      // dies and its owner sees only an error and an exit.
      Zone.root.run(
        () => Timer.run(() => throw StateError('Service gate $point crashed')),
      );
      await Completer<void>().future;
    }
    if (!File('$directory/$point.hold').existsSync()) return;
    _traceServiceTransport('gate held $point');
    while (!File('$directory/$point.release').existsSync() &&
        !File('$directory/release-all').existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  } on FileSystemException catch (error) {
    // A missing .reached file tells the test; shutdown itself must go on.
    stderr.writeln('Service gate $point: $error');
  }
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
Future<void> _clearStaleSocket(String path) async {
  try {
    await clearStaleSocket(path);
  } on SocketPathInUse catch (inUse) {
    throw _socketPathRefusal(inUse);
  }
}

/// Why another service's socket keeps an owner out of [runtime], or null.
Future<SocketPathInUse?> _runtimeInUse(String runtime) async {
  for (final name in ['application.sock', 'worker.sock']) {
    final inUse = await probeSocketPath('$runtime/$name');
    if (inUse != null) return inUse;
  }
  return null;
}

/// Publish [binding] without replacing a socket another owner published at
/// its path meanwhile (S2).
Future<void> _publish(
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

const _endpointRecordName = '.application-endpoint.json';
final _endpointTemporary = RegExp(r'^\.application-endpoint\.json\.\d+$');
final _endpointQuarantine = RegExp(
  r'^\.application-endpoint\.json\.invalid-(\d+)$',
);

/// The profile lock is independent of runtime overrides. An endpoint record lets
/// clients attach to that owner even when launched with a different runtime.
EndpointRecord readEndpointRecord(ProfilePaths profile) =>
    _readEndpointRecordAt(profile, '${profile.data}/$_endpointRecordName');

EndpointRecord _readEndpointRecordAt(ProfilePaths profile, String path) {
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
String _entryName(String path) => path.substring(path.lastIndexOf('/') + 1);

List<String> _endpointEntries(String data, RegExp name) => [
  for (final entry in Directory(data).listSync(followLinks: false))
    if (name.hasMatch(_entryName(entry.path))) entry.path,
];

// Renaming or deleting a symbolic link acts on the link, never its target.
void _renameEndpointEntry(String path, String target) =>
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      FileSystemEntityType.directory => Directory(path).renameSync(target),
      FileSystemEntityType.link => Link(path).renameSync(target),
      _ => File(path).renameSync(target),
    };

void _deleteEndpointEntry(String path) {
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
void _quarantineEndpointRecord(
  String data,
  String reason, {
  required String from,
  bool inUse = false,
}) {
  final record = '$data/$_endpointRecordName';
  final target = '$record.invalid-${DateTime.now().millisecondsSinceEpoch}';
  _renameEndpointEntry(from, target);
  stderr.writeln(
    inUse
        ? 'Set aside the application endpoint record as $target (runtime in '
              'use): $reason.'
        : 'Moved an invalid application endpoint record to $target: $reason.',
  );
  // A stamp too long for an int is not one this code wrote; drop it first.
  int stamp(String path) =>
      int.tryParse(_endpointQuarantine.firstMatch(_entryName(path))![1]!) ?? 0;
  final quarantined = _endpointEntries(data, _endpointQuarantine)
    ..sort((a, b) => stamp(a).compareTo(stamp(b)));
  for (final old in quarantined.take(max(0, quarantined.length - 3))) {
    _deleteEndpointEntry(old);
  }
}

/// Under the profile lock, take the predecessor's endpoint record out of
/// clients' sight at once, before this owner decides whether to adopt it, so
/// that no client reaches the runtime it names meanwhile (S4). An owner that
/// crashed while starting can leave a claimed record; it stays claimed unless
/// a newer record replaced it. Returns the claimed record's path.
String _claimEndpointRecord(String data) {
  final record = '$data/$_endpointRecordName';
  final claimed = '$record.claimed';
  if (FileSystemEntity.typeSync(record, followLinks: false) !=
      FileSystemEntityType.notFound) {
    _deleteEndpointEntry(claimed);
    _renameEndpointEntry(record, claimed);
  }
  return claimed;
}

// Only the local transport can create this marker. A peer's serialized error
// remains an ordinary RpcError, even if it copies the disconnect message.
class _ServiceTransportLost extends RpcError {
  _ServiceTransportLost(RpcErrorReason reason)
    : super(
        RpcErrorCode.unavailable,
        'Application service disconnected',
        reason: reason,
      );
}

/// Splits a byte stream into newline-terminated frames. Each frame is counted
/// exactly: with its newline it may be at most [limit] bytes. Bytes after the
/// last newline are held until it arrives; they never form a frame.
class _FrameSplitter {
  _FrameSplitter(this.limit);
  final int limit;
  final _partial = BytesBuilder(copy: false);

  /// Whether bytes of an unfinished frame are held.
  bool get hasPartial => _partial.isNotEmpty;

  /// The frames [chunk] completes, without newlines, or null as soon as a
  /// frame exceeds [limit].
  List<Uint8List>? add(Uint8List chunk) {
    final frames = <Uint8List>[];
    var start = 0;
    while (true) {
      final end = chunk.indexOf(10, start);
      final length = (end < 0 ? chunk.length : end) - start;
      if (_partial.length + length + 1 > limit) return null;
      _partial.add(Uint8List.sublistView(chunk, start, start + length));
      if (end < 0) return frames;
      frames.add(_partial.takeBytes());
      start = end + 1;
    }
  }
}

/// A complete frame that is a JSON object, or null for any other frame.
Map<String, dynamic>? _decodeFrame(Uint8List frame) {
  try {
    final value = jsonDecode(utf8.decode(frame));
    return value is Map<String, dynamic> ? value : null;
  } on FormatException {
    return null;
  }
}

/// The operations [ServiceClient.cancelAnswers] cancels.
final cancellableAnswers = {
  Operation.answerStream.wire,
  Operation.answer.wire,
  Operation.meetingsGenerate.wire,
  Operation.meetingsEnhance.wire,
};

/// Newline framed, multiplexed local RPC. No network listener is opened.
///
/// Every failure reaches callers as an [RpcError]. A lost connection (EOF, a
/// socket error, a frame cut off by EOF, or a frame over the limit) fails
/// requests already written with [RpcErrorReason.outcomeUnknown] and later
/// ones with [RpcErrorReason.notSent]. A complete frame that is not a JSON
/// object is a protocol error, reported to every caller as `internal`, with
/// [RpcErrorReason.outcomeUnknown] for requests already written.
class ServiceClient {
  final Socket socket;

  /// The socket path this client connected to. A profile's endpoint record
  /// can name another runtime by the time a caller looks again, so callers
  /// derive the connected owner's runtime from this, never from a second
  /// read (L9).
  final String endpoint;
  final int _maxMessageBytes;
  final _methods = <int, String>{};
  final _requestIds = <int, String>{};
  final _pending = <int, StreamController<Map<String, dynamic>>>{};
  final events = StreamController<Map<String, dynamic>>.broadcast();
  int _next = 0;
  bool _closed = false;
  bool _retired = false;
  Timer? _retirement;
  RpcError? _failure;

  /// Whether no request is sent on this connection any more: it is closed,
  /// or [retire]d and waiting for its last answers.
  bool get isClosed => _closed || _retired;
  ServiceClient._(this.socket, this._maxMessageBytes, this.endpoint) {
    unawaited(socket.done.catchError((Object _) {}));
    final frames = _FrameSplitter(_maxMessageBytes);
    socket.listen(
      (chunk) {
        if (_closed) return;
        final complete = frames.add(chunk);
        if (complete == null) {
          return _lose('a reply frame exceeds $_maxMessageBytes bytes');
        }
        for (final frame in complete) {
          if (_closed) return;
          _receive(frame);
        }
      },
      onError: (Object error) => _lose('$error'),
      onDone: () => _lose(frames.hasPartial ? 'EOF inside a frame' : 'EOF'),
      cancelOnError: true,
    );
  }

  void _receive(Uint8List frame) {
    final value = _decodeFrame(frame);
    if (value == null) {
      _traceServiceTransport(
        'client invalid frame ${utf8.decode(frame, allowMalformed: true)}',
      );
      const message = 'Application service sent an invalid reply';
      // Requests already written may have taken effect.
      return _fail(
        RpcError(
          RpcErrorCode.internal,
          message,
          reason: RpcErrorReason.outcomeUnknown,
        ),
        RpcError(RpcErrorCode.internal, message),
      );
    }
    if (value['event'] != null) {
      events.add(value);
      return;
    }
    final controller = _pending[value['id']];
    if (controller == null) return;
    controller.add(value);
    if (value['done'] == true) {
      _pending.remove(value['id']);
      _methods.remove(value['id']);
      _requestIds.remove(value['id']);
      unawaited(controller.close());
      _closeIfSettled();
    }
  }

  /// Stop sending on this connection, but let the requests already written
  /// settle. A closing owner that refused one of them answers every other
  /// itself, with a refusal or its own outcomeUnknown, before it ends the
  /// connection. Closing at once would fail them all locally as
  /// outcomeUnknown, so a refused one would never be sent to the next owner
  /// and its caller would be told it may have completed. Later requests fail
  /// at once as notSent. The connection closes when its last pending request
  /// settles, or after [grace].
  void retire({Duration grace = _retiredConnectionGrace}) {
    if (_closed || _retired) return;
    _retired = true;
    _traceServiceTransport('client retired with ${_pending.length} pending');
    _retirement = Timer(grace, () => unawaited(close()));
    _closeIfSettled();
  }

  void _closeIfSettled() {
    if (_retired && _pending.isEmpty) unawaited(close());
  }

  /// Bound each reply frame; the default matches the service's 16 MiB limit.
  static Future<ServiceClient> connect(
    String path, {
    int maxMessageBytes = maxServiceMessage,
    Duration connectTimeout = const Duration(seconds: 2),
  }) async {
    if (maxMessageBytes < 1) {
      throw ArgumentError.value(maxMessageBytes, 'maxMessageBytes');
    }
    return ServiceClient._(
      await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: connectTimeout,
      ),
      maxMessageBytes,
      path,
    );
  }

  void _lose(String cause) {
    _traceServiceTransport('client transport lost: $cause');
    _fail(
      _ServiceTransportLost(RpcErrorReason.outcomeUnknown),
      _ServiceTransportLost(RpcErrorReason.notSent),
    );
  }

  /// Fail requests already written with [inFlight] and every later one with
  /// [later]. The first failure wins.
  void _fail(RpcError inFlight, RpcError later) {
    if (_closed) return;
    _closed = true;
    _retirement?.cancel();
    _failure ??= later;
    for (final c in _pending.values) {
      c.addError(inFlight);
      unawaited(c.close());
    }
    _pending.clear();
    _methods.clear();
    _requestIds.clear();
    unawaited(events.close());
    socket.destroy();
  }

  Stream<Object?> stream(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    final id = ++_next;
    late StreamController<Map<String, dynamic>> controller;
    controller = StreamController(
      onCancel: () {
        _methods.remove(id);
        _requestIds.remove(id);
        if (_pending.remove(id) != null && !_closed) {
          socket.writeln(jsonEncode({'cancel': id}));
          _closeIfSettled();
        }
      },
    );
    final frame = isClosed
        ? null
        : utf8.encode(jsonEncode({'id': id, 'method': method, 'args': args}));
    if (frame == null) {
      controller.addError(
        _failure ?? _ServiceTransportLost(RpcErrorReason.notSent),
      );
      unawaited(controller.close());
    } else if (frame.length + 1 > _maxServiceFrame) {
      // The service drops a connection whose request exceeds its limit, which
      // for the desktop also stops recording. It counts bytes per read too.
      controller.addError(
        RpcError(
          RpcErrorCode.invalidArgument,
          'Request exceeds ${_maxServiceFrame ~/ (1024 * 1024)} MiB; '
          'send less data.',
        ),
      );
      unawaited(controller.close());
    } else {
      _pending[id] = controller;
      _methods[id] = method;
      if (args['requestId'] is String) {
        _requestIds[id] = args['requestId'] as String;
      }
      socket
        ..add(frame)
        ..add(const [10]);
    }
    return controller.stream
        .where((v) => v.containsKey('result') || v.containsKey('error'))
        .map((v) {
          if (v['error'] != null) throw RpcError.from(v['error'] as Object);
          return v['result'];
        });
  }

  Future<Object?> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    Object? result;
    await for (final value in stream(method, args)) {
      result = value;
    }
    return result;
  }

  bool cancelAnswers({String? requestId}) {
    final ids = _methods.entries
        .where(
          (entry) =>
              cancellableAnswers.contains(entry.value) &&
              (requestId == null || _requestIds[entry.key] == requestId),
        )
        .map((e) => e.key)
        .toList();
    for (final id in ids) {
      socket.writeln(jsonEncode({'cancel': id}));
      final pending = _pending.remove(id);
      _methods.remove(id);
      _requestIds.remove(id);
      pending?.addError(RpcError(RpcErrorCode.cancelled, 'Answer cancelled'));
      if (pending != null) unawaited(pending.close());
    }
    if (ids.isNotEmpty) _closeIfSettled();
    return ids.isNotEmpty;
  }

  Future<void> close() async {
    _fail(
      RpcError(
        RpcErrorCode.unavailable,
        'Application service disconnected',
        reason: RpcErrorReason.outcomeUnknown,
      ),
      RpcError(
        RpcErrorCode.unavailable,
        'Application service disconnected',
        reason: RpcErrorReason.notSent,
      ),
    );
  }
}

/// Whether [error] says its request never took effect, so sending it once
/// more, after a handoff, is safe: a closing owner refused it before dispatch,
/// or it never reached a live socket. An `outcomeUnknown` request is never
/// resent.
bool _resendable(RpcError error) =>
    isClosingRefusal(error) || error.reason == RpcErrorReason.notSent;

/// Reattach on the next request after a disconnect; never replay a request
/// whose commit status is unknown.
class ServiceConnection {
  final ProfilePaths profile;
  ServiceClient? _client;
  Future<ServiceClient>? _connecting;
  bool _closed = false;
  ServiceConnection(this.profile);
  Future<ServiceClient> connect() async {
    if (_closed) throw StateError('Client closed');
    final current = _client;
    if (current != null && !current.isClosed) return current;
    return _connecting ??= _open().whenComplete(() => _connecting = null);
  }

  Future<ServiceClient> _open() async {
    final client = await ensureService(profile);
    if (_closed) {
      await client.close();
      throw StateError('Client closed');
    }
    return _client = client;
  }

  /// A request refused by a closing owner, or never sent, before any result
  /// arrived is sent once more after [connect] hands off to the next owner
  /// (SL-9). Anything else, including `outcomeUnknown`, reaches the caller.
  /// Cancelling the stream cancels the request at once.
  Stream<Object?> stream(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    late final StreamController<Object?> output;
    StreamSubscription<Object?>? request;
    var cancelled = false;
    Future<void> send({required bool resent}) async {
      final ServiceClient client;
      try {
        client = await connect();
      } catch (error, stack) {
        if (!cancelled) {
          output.addError(error, stack);
          unawaited(output.close());
        }
        return;
      }
      if (cancelled) return;
      var received = false;
      var handedOff = false;
      request = client
          .stream(method, args)
          .listen(
            (value) {
              received = true;
              output.add(value);
            },
            onError: (Object error, StackTrace stack) {
              if (!resent &&
                  !received &&
                  error is RpcError &&
                  _resendable(error)) {
                handedOff = true;
                _traceServiceTransport('connection resends $method: $error');
                // New requests go to the next owner. The closing owner
                // answers this connection's other requests itself, so it is
                // retired rather than closed: closing it would report them
                // as possibly completed, and never resend a refused one.
                if (identical(_client, client)) _client = null;
                client.retire();
                unawaited(send(resent: true));
                return;
              }
              output.addError(error, stack);
            },
            onDone: () {
              if (!handedOff) unawaited(output.close());
            },
          );
    }

    output = StreamController<Object?>(
      onListen: () => unawaited(send(resent: false)),
      onPause: () => request?.pause(),
      onResume: () => request?.resume(),
      onCancel: () {
        cancelled = true;
        return request?.cancel();
      },
    );
    return output.stream;
  }

  Future<void> close() async {
    _closed = true;
    await _client?.close();
  }
}

class _RequestLease {
  final String id;
  final String method;
  bool cancelled = false;
  // Set only while the request waits for desktop approval or helper
  // readiness, and cleared just before dispatch. A close refuses a waiting
  // request like a new one; any other is outcomeUnknown.
  bool waiting = false;
  _RequestLease(this.id, this.method);
}

class ApplicationService {
  final Domain domain;
  final Application application;
  late final AgentAccessGate access;
  final ServerSocket listener;
  final ServiceSocketBinding _binding;
  final String path;
  final RandomAccessFile lock;
  final RandomAccessFile? installationLock;
  final _clients = <Socket>{};
  final _leases = <Socket, Map<int, _RequestLease>>{};
  final _subscriptions = <Socket, Map<int, StreamSubscription<Object?>>>{};
  StreamSubscription<void>? _changes;
  StreamSubscription<void>? _captureLevels;
  Timer? _heartbeat;
  Timer? _desktopShutdown;
  Duration _desktopDetachGrace = const Duration(seconds: 1);

  /// Whether the shutdown after the last desktop left is pending. Tests
  /// observe it instead of sleeping past the grace.
  bool get desktopShutdownScheduled => _desktopShutdown?.isActive ?? false;
  final _desktopClients = <Socket>{};
  bool _closing = false;
  Future<void>? _shutdown;
  void Function()? _onDraining;
  Future<void> Function()? _beforeReleaseOwnership;
  final _closed = Completer<void>();
  Future<void> get closed => _closed.future;
  int _connectionSequence = 0;
  Future<void> _ready = Future<void>.value();
  ApplicationService._(
    this.domain,
    this._binding,
    this.path,
    this.lock,
    this.installationLock,
    this.application,
  ) : listener = _binding.listener {
    final token = base64Url.encode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final tokenFile = File(
      '${File(domain.store.path).parent.path}/.desktop-capability',
    );
    if (FileSystemEntity.typeSync(tokenFile.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Desktop capability must not be a symbolic link');
    }
    tokenFile.writeAsStringSync(token);
    if (Process.runSync('/bin/chmod', ['600', tokenFile.path]).exitCode != 0) {
      throw StateError('Cannot protect desktop capability');
    }
    access = AgentAccessGate(
      token,
      (host, event) => _send(host as Socket, event),
    );
    _changes = application.changes.stream.listen((_) => _broadcast());
    _captureLevels = application.captureLevelChanges.stream.listen((_) {
      if (_closing) return;
      for (final client in _clients) {
        _send(client, {
          'event': 'capture_levels',
          'volumes': application.recording?.currentVolumes ?? <double>[],
        });
      }
    });
    _heartbeat = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _broadcast(),
    );
  }

  /// Stop the timers and subscriptions of a service whose startup failed.
  void _discard() {
    _heartbeat?.cancel();
    unawaited(_changes?.cancel());
    unawaited(_captureLevels?.cancel());
  }

  /// [desktopDetachGrace] is how long the service waits for a desktop to
  /// reattach after its approval connection closes before it shuts down.
  static Future<ApplicationService> start(
    ProfilePaths profile, {
    SearchCallbacks? webSearch,
    bool internalWorker = false,
    Duration desktopDetachGrace = const Duration(seconds: 1),
  }) async {
    // This must precede native loads, database opens, and worker creation.
    final installationLock = acquireInstallationLock();
    void Function()? releaseLocalOwner;
    try {
      releaseLocalOwner = _retainLocalServiceOwner(profile.data);
      final service = await _start(
        profile,
        installationLock,
        webSearch: webSearch,
        internalWorker: internalWorker,
      );
      service._desktopDetachGrace = desktopDetachGrace;
      unawaited(service.closed.whenComplete(releaseLocalOwner));
      return service;
    } catch (_) {
      releaseLocalOwner?.call();
      installationLock?.closeSync();
      rethrow;
    }
  }

  static Future<ApplicationService> _start(
    ProfilePaths profile,
    RandomAccessFile? installationLock, {
    SearchCallbacks? webSearch,
    bool internalWorker = false,
  }) async {
    privateDirectory(profile.data, repairOwnedPermissions: true);
    // Configure native state only when a native installation is present. Tests
    // and administration may use the storage-only service without model workers.
    if (runtimeConfiguration['FORESIGHT_NATIVE'] != null) {
      configureProfileRuntime(profile.data);
    }
    privateRuntime(profile);
    var path = '${profile.runtime}/application.sock';
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
        if (!_lockContended(error)) rethrow;
        if (serviceGatesEnabled) await serviceGate('start.lock_contended');
        throw ServiceOwnershipContended(
          'Another application service owns this profile: $error',
        );
      }
      // A launch that reached the lock only after its launcher stopped
      // waiting (it attached to another owner, or gave up) serves nobody.
      if (_launchLeaseWithdrawn(profile)) {
        _traceServiceTransport('launch lease withdrawn; not serving');
        throw ServiceLaunchWithdrawn(
          'The launcher that started this service stopped waiting for it, so '
          'it exits without serving.',
        );
      }
    } catch (_) {
      lock.closeSync();
      rethrow;
    }
    Store? store;
    Helper? helper;
    Application? startedApplication;
    ServiceSocketBinding? binding;
    final endpointRecord = File('${profile.data}/$_endpointRecordName');
    final temporary = File('${endpointRecord.path}.$pid');
    // A predecessor's valid record names the runtime this attempt adopts. Keep
    // it if startup fails; remove only a record this attempt published itself.
    var adoptedRecord = false;
    var publishedRecord = false;
    String? claimed;
    try {
      // This owner holds the profile lock; any endpoint record is a
      // predecessor's. Claim it before anything that can wait.
      claimed = _claimEndpointRecord(profile.data);
      if (serviceGatesEnabled) await serviceGate('start.locked');
      // Only an owner writes temporary records, so any left now are stale.
      _endpointEntries(
        profile.data,
        _endpointTemporary,
      ).forEach(_deleteEndpointEntry);
      // An unclean predecessor can leave a healthy helper at this endpoint.
      // Reuse that runtime until a clean shutdown releases its workers. An
      // invalid record names no usable runtime, so it is not adopted.
      switch (_readEndpointRecordAt(profile, claimed)) {
        case EndpointValid(:final runtime):
          // Another profile's service may use that runtime by now, for
          // example one sharing it; then this profile starts in its own (S1).
          final inUse = await _runtimeInUse(runtime);
          if (inUse != null) {
            _quarantineEndpointRecord(
              profile.data,
              "another profile's service uses it ($inUse)",
              from: claimed,
              inUse: true,
            );
            break;
          }
          adoptedRecord = true;
          stderr.writeln(
            'Application service: the previous owner left its endpoint '
            'record; adopting its runtime.',
          );
          profile = ProfilePaths(profile.data, runtime);
        case EndpointInvalid(:final reason):
          _quarantineEndpointRecord(profile.data, reason, from: claimed);
        case EndpointAbsent():
          break;
      }
      path = '${profile.runtime}/application.sock';
      // Every supported public socket path must also fit the private endpoint.
      if (internalWorker) path = '${profile.runtime}/worker.sock';
      await _clearStaleSocket(path);
      sweepStaleSpeechAudio(profile.data);
      store = Store('${profile.data}/application.db');
      await store.verifyRegisteredModels(rejectInvalidRegistrations: true);
      final interrupted = store
          .rows(
            "SELECT id FROM meetings WHERE state IN ('recording','transcribing','paused')",
          )
          .map((row) => row['id'] as int)
          .toList();
      store.db.execute(
        "UPDATE meetings SET state='interrupted' WHERE state IN ('recording','transcribing','paused')",
      );
      helper = Helper(
        '${profile.runtime}/helper.sock',
        '${profile.data}/helper',
      );
      final domain = Domain(store, helper, webSearch: webSearch);
      final application = Application(domain)..profileId = profile.identity;
      startedApplication = application;
      application.importPolicy = ImportPolicy(profile.data, () {
        final saved = store!.preference('importRoots', '[]');
        return (jsonDecode(saved) as List).cast<String>();
      });
      application.startBackground();
      binding = await ServiceSocketBinding.bind(path);
      temporary.writeAsStringSync(
        jsonEncode({'data': profile.data, 'runtime': profile.runtime}),
        flush: true,
      );
      if (Process.runSync('/bin/chmod', ['600', temporary.path]).exitCode !=
          0) {
        throw StateError('Cannot protect service endpoint record');
      }
      temporary.renameSync(endpointRecord.path);
      publishedRecord = true;
      // The published record names the adopted runtime, if any.
      _deleteEndpointEntry(claimed);
      final service = ApplicationService._(
        domain,
        binding,
        path,
        lock,
        installationLock,
        application,
      );
      try {
        await _publish(binding, service._accept);
      } catch (_) {
        service._discard();
        rethrow;
      }
      final manifest = runtimeConfiguration['FORESIGHT_MODEL_MANIFEST'];
      if (manifest != null && File(manifest).existsSync()) {
        domain.initialize(
          registerInstalledModels(store, manifest).then<void>((_) {}),
        );
      }
      helper.changed = service._broadcast;
      helper.onReady = () async {
        await domain.resume();
        for (final id in interrupted.toList()) {
          try {
            await application.indexMeeting(id);
            interrupted.remove(id);
          } catch (error) {
            stderr.writeln('Interrupted meeting indexing: $error');
          }
        }
      };
      service._ready = helper.start().catchError((Object e) {
        stderr.writeln('Helper startup: $e');
        service._broadcast();
      });
      return service;
    } catch (_) {
      // Report cleanup failures, but keep the startup failure and always
      // release ownership.
      Future<void> cleanup(FutureOr<void> Function() step) async {
        try {
          await step();
        } catch (error) {
          stderr.writeln('Application service startup cleanup: $error');
        }
      }

      try {
        // Background timers would otherwise keep a worker isolate alive.
        await cleanup(() => startedApplication?.close());
        await cleanup(() => binding?.listener.close());
        // Only a socket this attempt published is its own to remove; one
        // that refused to clear the path, or replaced this one, belongs to
        // another owner.
        await cleanup(() => binding?.unpublish());
        await cleanup(() => helper?.close());
        await cleanup(() => store?.close());
        // Remove the record while the lock is still held, so no launcher sees
        // a record without an owner that this failed attempt left behind.
        await cleanup(() {
          if (publishedRecord &&
              !adoptedRecord &&
              FileSystemEntity.typeSync(
                    endpointRecord.path,
                    followLinks: false,
                  ) !=
                  FileSystemEntityType.notFound) {
            endpointRecord.deleteSync();
          }
        });
        // A claimed record this attempt neither set aside nor replaced goes
        // back, so the next owner adopts its runtime again.
        await cleanup(() {
          if (!publishedRecord &&
              claimed != null &&
              FileSystemEntity.typeSync(claimed, followLinks: false) !=
                  FileSystemEntityType.notFound) {
            _renameEndpointEntry(claimed, endpointRecord.path);
          }
        });
        await cleanup(() {
          if (FileSystemEntity.typeSync(temporary.path, followLinks: false) ==
              FileSystemEntityType.file) {
            temporary.deleteSync();
          }
        });
      } finally {
        lock.closeSync();
      }
      rethrow;
    }
  }

  /// Writes [message] to [client] and says whether it got there. A reply that
  /// is too large or cannot be encoded is replaced by an error; such an event
  /// is dropped. A failed write closes the connection.
  EventDelivery _send(Socket client, Map<String, Object?> message) {
    try {
      _traceServiceTransport(
        'worker send peer=${identityHashCode(client)} id=${message['id']} '
        'event=${message['event']} done=${message['done']}',
      );
      Uint8List? frame;
      String? failure;
      var delivery = EventDelivery.sent;
      try {
        frame = utf8.encode(jsonEncode(message));
        // A client drops its whole connection on a frame over the limit, and
        // losing the desktop's connection stops its recording. Fail only the
        // request instead.
        if (frame.length + 1 > _maxServiceFrame) {
          delivery = EventDelivery.tooLarge;
          failure =
              'Reply exceeds ${_maxServiceFrame ~/ (1024 * 1024)} MiB; '
              'request fewer items.';
        }
      } on JsonUnsupportedObjectError {
        delivery = EventDelivery.unencodable;
        failure =
            'Reply contains a value JSON cannot represent, such as NaN or '
            'Infinity.';
      }
      if (failure != null) {
        final id = message['id'];
        _traceServiceTransport(
          'worker unsendable peer=${identityHashCode(client)} id=$id '
          'event=${message['event']} bytes=${frame?.length} $failure',
        );
        // A dropped snapshot is superseded by the next one. The approval gate
        // fails its request instead of waiting for a decision.
        if (id == null) return delivery;
        // No later frame may follow this request's terminal error.
        if (id is int) _cancel(client, id);
        frame = utf8.encode(
          jsonEncode({
            'id': id,
            'error': RpcError(RpcErrorCode.internal, failure).toJson(),
            'done': true,
          }),
        );
      }
      client
        ..add(frame!)
        ..add(const [10]);
      return delivery;
    } catch (_) {
      client.destroy();
      return EventDelivery.writeFailed;
    }
  }

  void _broadcast() {
    if (_closing) return;
    final message = {
      'event': 'changed',
      'capture': application.captureState,
      'revision': domain.store.dataRevision,
      'sources_paused': domain.sourcesPaused,
      'generation': application.generationState,
      'web_search_available': domain.webSearchAvailable,
      'google': application.googleState,
      'helper': domain.helper.snapshot?.toProto3Json(),
      'helper_state': domain.helper.state,
      'workspace_epoch': domain.store.workspaceEpoch,
    };
    for (final client in _clients) {
      _send(client, message);
    }
  }

  void _accept(Socket client) {
    _traceServiceTransport('worker accept peer=${identityHashCode(client)}');
    final conversation =
        'connection-$pid-${DateTime.now().microsecondsSinceEpoch}-${++_connectionSequence}';
    unawaited(client.done.catchError((Object _) {}));
    _clients.add(client);
    _subscriptions[client] = {};
    _leases[client] = {};
    var bytes = 0;
    client
        .map((chunk) {
          bytes += chunk.length;
          if (bytes > maxServiceMessage) throw StateError('Request too large');
          return chunk;
        })
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            bytes = 0;
            try {
              final request = jsonDecode(line) as Map<String, dynamic>;
              _traceServiceTransport(
                'worker request peer=${identityHashCode(client)} '
                'id=${request['id']} method=${request['method']}',
              );
              if (request['cancel'] is int) {
                _cancel(client, request['cancel'] as int);
                return;
              }
              final id = request['id'];
              if (id is! int ||
                  request['method'] is! String ||
                  request['args'] is! Map) {
                throw FormatException('Invalid request');
              }
              if (_closing) {
                _send(client, {
                  'id': id,
                  'error': _closingRefusal().toJson(),
                  'done': true,
                });
                return;
              }
              final method = request['method'] as String;
              final securityArgs = Map<String, dynamic>.from(
                request['args'] as Map,
              );
              if (method.startsWith('security.')) {
                try {
                  if (method == Operation.securityAttachDesktop.wire) {
                    access.attach(client, securityArgs['token'] as String);
                    _desktopClients.add(client);
                    _desktopShutdown?.cancel();
                  } else if (method == Operation.securityDetachDesktop.wire) {
                    if (!access.isHost(client)) {
                      throw RpcError(
                        RpcErrorCode.denied,
                        'Not the desktop approval connection',
                      );
                    }
                    access.detach(client);
                    unawaited(
                      application.stopRecording().catchError((Object error) {
                        stderr.writeln(
                          'Stop recording on desktop detach: $error',
                        );
                      }),
                    );
                  } else if (method == Operation.securityDecide.wire) {
                    access.decide(
                      client,
                      securityArgs['approval_id'] as String,
                      securityArgs['allow'] == true,
                    );
                  } else if (method == Operation.securityAllowImportRoot.wire) {
                    if (!access.isHost(client)) {
                      throw RpcError(
                        RpcErrorCode.denied,
                        'Only the desktop can select import folders',
                      );
                    }
                    final root = Directory(
                      securityArgs['path'] as String,
                    ).resolveSymbolicLinksSync();
                    final roots =
                        (jsonDecode(
                                  domain.store.preference('importRoots', '[]'),
                                )
                                as List)
                            .cast<String>();
                    domain.store.setPreference(
                      'importRoots',
                      jsonEncode({...roots, root}.toList()),
                    );
                  } else {
                    throw StateError('Unknown security operation');
                  }
                  _send(client, {'id': id, 'result': true, 'done': true});
                } catch (e) {
                  _send(client, {
                    'id': id,
                    'error': RpcError.from(e).toJson(),
                    'done': true,
                  });
                }
                return;
              }
              if (method == Operation.status.wire &&
                  securityArgs['desktop'] == true) {
                // Reserve desktop lifetime atomically before its startup snapshot.
                // This authenticates liveness only: visible approvals still need
                // security.attach_desktop and its separate host assignment.
                if (securityArgs['token'] != access.desktopToken ||
                    access.desktopToken.isEmpty) {
                  _send(client, {
                    'id': id,
                    'error': RpcError(
                      RpcErrorCode.denied,
                      'Invalid desktop capability',
                    ).toJson(),
                    'done': true,
                  });
                  return;
                }
                _desktopClients.add(client);
                _desktopShutdown?.cancel();
              }
              if (request['method'] == Operation.serviceStopIfIdle.wire) {
                unawaited(
                  _stopIfIdle(
                    client,
                    id,
                    Map<String, dynamic>.from(request['args'] as Map),
                  ),
                );
                return;
              }
              if ((_subscriptions[client]?.length ?? 0) >= 32) {
                _send(client, {
                  'id': id,
                  'error': RpcError(
                    RpcErrorCode.busy,
                    'Too many active requests',
                  ).toJson(),
                  'done': true,
                });
                return;
              }
              final args = Map<String, dynamic>.from(request['args'] as Map);
              args.putIfAbsent('conversation', () => conversation);
              final lease = _RequestLease(
                'rpc-$conversation-$id',
                request['method'] as String,
              );
              _leases[client]![id] = lease;
              args['requestId'] = lease.id;
              lease.waiting = true;
              final results = Stream.fromFuture(
                Future.sync(() {
                  // A request from a cleared workspace fails before it can
                  // ask the desktop for approval.
                  application.checkWorkspaceEpoch(args);
                  return access.authorize(
                    client,
                    lease.method,
                    args,
                    current: () => !lease.cancelled,
                  );
                }),
              ).asyncExpand((_) => _results(client, args, lease));
              _subscriptions[client]![id] = results.listen(
                (value) =>
                    _send(client, {'id': id, 'result': value, 'done': false}),
                onError: (Object e) {
                  _send(client, {
                    'id': id,
                    'error': RpcError.from(e).toJson(),
                    'done': true,
                  });
                  _subscriptions[client]?.remove(id);
                  _leases[client]?.remove(id);
                },
                onDone: () {
                  _send(client, {'id': id, 'done': true});
                  _subscriptions[client]?.remove(id);
                  _leases[client]?.remove(id);
                },
                cancelOnError: true,
              );
            } catch (e) {
              _send(client, {'error': RpcError.from(e).toJson(), 'done': true});
            }
          },
          onError: (Object _) => client.destroy(),
          onDone: () {
            final wasHost = access.isHost(client);
            access.detach(client);
            if (wasHost) {
              unawaited(
                application.stopRecording().catchError((Object e) {
                  stderr.writeln('Stop capture after desktop closed: $e');
                }),
              );
            }
            _clients.remove(client);
            for (final id in _leases[client]?.keys.toList() ?? <int>[]) {
              _cancel(client, id);
            }
            _leases.remove(client);
            for (final s
                in _subscriptions.remove(client)?.values ??
                    <StreamSubscription<Object?>>[]) {
              unawaited(_cancelSubscription(s));
            }
            client.destroy();
            if (_desktopClients.remove(client) &&
                _desktopClients.isEmpty &&
                !access.hasHost &&
                !_closing) {
              // Allow a transient socket reconnect. Once the desktop has gone,
              // agent connections must not keep its helper/models alive forever.
              _desktopShutdown?.cancel();
              _desktopShutdown = Timer(_desktopDetachGrace, () {
                if (_desktopClients.isNotEmpty || access.hasHost || _closing) {
                  return;
                }
                unawaited(
                  close().catchError((Object error) {
                    stderr.writeln('Shutdown after desktop closed: $error');
                  }),
                );
              });
            }
          },
        );
  }

  Stream<Object?> _results(
    Socket client,
    Map<String, dynamic> args,
    _RequestLease lease,
  ) {
    if (lease.cancelled) {
      return Stream.error(
        RpcError(RpcErrorCode.cancelled, 'Operation cancelled'),
      );
    }
    if (lease.method == Operation.answerStream.wire) {
      return Stream.fromFuture(_ready).asyncExpand((_) {
        lease.waiting = false;
        return (args['web_search'] == true
            ? application.askWithWebInConversation
            : application.askInConversation)(
          args['question'] as String,
          args['conversation'] as String,
          requestId: lease.id,
          meetingId: args['meeting_id'] as int?,
          current: () => !lease.cancelled,
        );
      });
    }
    if (lease.method == Operation.googleSignIn.wire ||
        lease.method == Operation.googleAddAccount.wire) {
      lease.waiting = false;
      return application.signIn(
        lease.id,
        addAccount: lease.method == Operation.googleAddAccount.wire,
      );
    }
    return Stream.fromFuture(_execute(lease.method, args, lease));
  }

  Future<void> _stopIfIdle(
    Socket client,
    int id,
    Map<String, dynamic> args,
  ) async {
    try {
      if ((args['expected_pid'] != null && args['expected_pid'] != pid) ||
          (args['installation_root'] != null &&
              args['installation_root'] != configuredInstallationRoot) ||
          (args['runtime_revision'] != null &&
              args['runtime_revision'] !=
                  runtimeConfiguration['FORESIGHT_RUNTIME_REVISION'])) {
        throw RpcError(
          RpcErrorCode.cancelled,
          'Application service ownership changed before idle shutdown; retry without replacing the app.',
        );
      }
      final capture = application.captureState;
      if (capture['active'] == true || capture['finishing'] == true) {
        throw RpcError(
          RpcErrorCode.busy,
          'Recording is active or finalizing. Stop recording and wait for the final transcript before upgrading.',
        );
      }
      // The request callback and close's barrier execute without yielding. In
      // particular, a recording-start request awaiting helper/model readiness
      // must not slip between an idle status check and shutdown acceptance.
      if (_leases.values.any(
        (leases) =>
            leases.values.any((lease) => lease.method != Operation.status.wire),
      )) {
        throw RpcError(
          RpcErrorCode.busy,
          'Application operations are in progress. Retry the upgrade after they finish.',
        );
      }
      await close(acknowledgementClient: client);
      if (!domain.helper.shutdownVerified) {
        throw StateError(
          'Helper shutdown could not be verified. The application was not cleared for upgrade.',
        );
      }
      _send(client, {
        'id': id,
        'result': {'stopped': true, 'shutdown_verified': true},
        'done': true,
      });
    } catch (error) {
      _send(client, {
        'id': id,
        'error': RpcError.from(error).toJson(),
        'done': true,
      });
    }
    try {
      await client.flush();
    } catch (_) {
      /* Missing acknowledgement is failure for the caller. */
    }
    if (_closing) client.destroy();
  }

  Future<Object?> _execute(
    String method,
    Map<String, dynamic> args,
    _RequestLease lease,
  ) async {
    // Nothing has been dispatched yet, so these are closing refusals too.
    if (_closing) throw _closingRefusal();
    if (Operation.parse(method).requiresHelper) await _ready;
    if (_closing) throw _closingRefusal();
    if ((method == Operation.meetingsStart.wire ||
            method == Operation.meetingsResume.wire) &&
        !access.hasHost) {
      throw RpcError(
        RpcErrorCode.denied,
        'Recording requires an open desktop indicator',
      );
    }
    lease.waiting = false;
    final result = await application.call(
      method,
      args,
      current: () => !lease.cancelled,
    );
    // The operation has committed; a lifecycle test may hold its reply here.
    if (serviceGatesEnabled) await serviceGate('request.committed.$method');
    return result;
  }

  void _cancel(Socket client, int id) {
    final lease = _leases[client]?.remove(id);
    if (lease != null) {
      lease.cancelled = true;
      if (lease.method == Operation.googleSignIn.wire ||
          lease.method == Operation.googleAddAccount.wire) {
        application.cancelSignIn(lease.id);
      }
      domain.generator?.cancel(requestId: lease.id);
    }
    final subscription = _subscriptions[client]?.remove(id);
    if (subscription != null) unawaited(_cancelSubscription(subscription));
  }

  Future<void> _cancelSubscription(
    StreamSubscription<Object?> subscription,
  ) async {
    try {
      await subscription.cancel();
    } catch (error) {
      // Async generators can fail during cancellation cleanup. Keep that failure
      // scoped to the cancelled request rather than terminating the service.
      stderr.writeln('Request cancellation cleanup: $error');
    }
  }

  Future<void> close({Socket? acknowledgementClient}) => _shutdown ??=
      _close(acknowledgementClient: acknowledgementClient).whenComplete(() {
        if (!_closed.isCompleted) _closed.complete();
      });

  Future<void> _close({Socket? acknowledgementClient}) async {
    _closing = true;
    _heartbeat?.cancel();
    _desktopShutdown?.cancel();
    // An isolated frontend refuses new connections from here on.
    _onDraining?.call();
    // Every request in flight gets a terminal frame before its lease is
    // cancelled. Nothing awaits before this loop, so no request can complete
    // in between: a client sees either its result or this error (SL-4). One
    // still waiting for approval or the helper was never dispatched, so it is
    // refused like a new request and may be sent to the next owner; any
    // other may have taken effect.
    final unknown = RpcError(
      RpcErrorCode.unavailable,
      _outcomeUnknownMessage,
      reason: RpcErrorReason.outcomeUnknown,
    ).toJson();
    final refused = _closingRefusal().toJson();
    for (final client in _leases.keys.toList()) {
      final leases = _leases[client]!;
      for (final id in leases.keys.toList()) {
        _send(client, {
          'id': id,
          'error': leases[id]!.waiting ? refused : unknown,
          'done': true,
        });
        _cancel(client, id);
      }
    }
    Object? failure;
    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        failure ??= error;
      }
    }

    // New requests are refused and in-flight leases cancelled from here.
    if (serviceGatesEnabled) await serviceGate('close.begin');
    // Every request that was in flight has been sent its terminal frame.
    if (serviceGatesEnabled) await serviceGate('close.leases_terminated');
    // Application.close synchronously rejects new business calls and cancels
    // background timers before its first await.
    await attempt(application.close);
    await attempt(() async {
      await _changes?.cancel();
      await _captureLevels?.cancel();
    });
    await attempt(domain.close);
    await attempt(() => domain.generator?.close());
    await attempt(domain.helper.close);
    if (serviceGatesEnabled) await serviceGate('close.helper_closed');
    // Stop accepting first, so every connection is flushed and closed below.
    await attempt(listener.close);
    // Deliver terminal frames and closing refusals before the connections
    // close, but never let a client that stopped reading hold shutdown.
    final peers = [
      for (final client in _clients)
        if (client != acknowledgementClient) client,
    ];
    await Future.wait([
      for (final peer in peers) _flushQuietly(peer),
    ]).timeout(_closingFlushBound, onTimeout: () => const []);
    for (final peer in peers) {
      peer.destroy();
    }
    if (serviceGatesEnabled) await serviceGate('close.listener_closed');
    await attempt(domain.store.close);
    // The listener is closed, so another profile's owner sharing this runtime
    // may have published at this path since; remove only this socket (S3).
    await attempt(_binding.unpublish);
    if (serviceGatesEnabled) await serviceGate('close.before_frontend_release');
    await attempt(() async {
      await _beforeReleaseOwnership?.call();
    });
    // The record outlives every socket of this owner: worker socket, public
    // socket, record, then lock. A record therefore always means its owner is
    // live, draining or crashed (SL-3).
    await attempt(() async {
      final endpoint = File(
        '${File(domain.store.path).parent.path}/.application-endpoint.json',
      );
      if (serviceGatesEnabled) {
        await serviceGate('close.before_record_delete');
      }
      if (domain.helper.shutdownVerified &&
          failure == null &&
          endpoint.existsSync()) {
        endpoint.deleteSync();
      }
    });
    if (serviceGatesEnabled) await serviceGate('close.before_lock_release');
    await attempt(lock.closeSync);
    await attempt(() => installationLock?.closeSync());
    if (failure != null) {
      throw StateError('Application shutdown failed: $failure');
    }
  }
}

/// Public socket transport lives on the main service isolate. The complete
/// Domain (SQLite connections, native handles, model ownership, approvals and
/// request leases) lives in one long-lived worker isolate. Byte streams preserve
/// multiplexed requests, events, cancellation and shutdown acknowledgements.
///
/// Once the worker begins closing (its `draining` message) or this frontend is
/// asked to close, new connections are no longer bridged: [_refuse] answers
/// their requests with the closing refusal until the public socket is removed.
/// Attached clients keep their bridges, so they receive the worker's terminal
/// frames and refusals before it closes their connections. Only a worker that
/// exits unexpectedly leaves them with a bare EOF.
class IsolatedApplicationService {
  final String _dataPath;
  final ReceivePort _messages;
  final ReceivePort _errors;
  final ReceivePort _exits;
  final _ready = Completer<void>();
  final _closed = Completer<void>();
  final _peers = <Socket>{};
  final _refused = <Socket>{};
  final _bridges = <Future<void>>{};
  SendPort? _control;
  ServiceSocketBinding? _binding;
  Future<void>? _listening;
  bool _publicClosing = false;
  String? _publicPath;
  String? _workerPath;
  Object? _failure;
  // This frontend asked the worker to close.
  bool _closing = false;
  // The worker announced that it is closing.
  bool _workerClosing = false;
  // New connections get the closing refusal instead of a bridge.
  bool _draining = false;
  Future<void>? _shutdown;
  Future<void>? _finishing;
  final _workerExited = Completer<void>();
  bool _publicRemoved = false;
  // Set once the public socket is released; later refusals end at once.
  bool _refusalsEnded = false;
  Future<void> get closed => _closed.future;
  IsolatedApplicationService._(
    this._dataPath,
    this._messages,
    this._errors,
    this._exits,
  );

  static Future<IsolatedApplicationService> start(ProfilePaths profile) async {
    // The worker only gets the runtime path; check its parent here.
    privateRuntime(profile);
    final host = IsolatedApplicationService._(
      profile.data,
      ReceivePort(),
      ReceivePort(),
      ReceivePort(),
    );
    host._messages.listen(host._message);
    host._errors.listen((dynamic error) {
      _traceServiceTransport('worker uncaught error $error');
      host._failure = StateError('Application worker failed: $error');
      if (!host._ready.isCompleted) host._ready.completeError(host._failure!);
    });
    host._exits.listen((_) {
      _traceServiceTransport(
        'worker exit received failed=${host._failure != null}',
      );
      final unexpected =
          host._ready.isCompleted && !host._closing && !host._workerClosing;
      if (!host._workerExited.isCompleted) host._workerExited.complete();
      if (!host._ready.isCompleted) {
        host._ready.completeError(
          host._failure ??
              StateError('Application worker exited during startup'),
        );
      }
      if (unexpected) host._workerLost();
      unawaited(host._finish());
    });
    var spawned = false;
    try {
      final releaseLocalOwner = _retainLocalServiceOwner(profile.data);
      unawaited(host.closed.whenComplete(releaseLocalOwner));
      await Isolate.spawn(
        _applicationServiceWorker,
        [
          host._messages.sendPort,
          profile.data,
          profile.runtime,
          Map<String, String>.from(runtimeConfiguration.environment),
        ],
        onError: host._errors.sendPort,
        onExit: host._exits.sendPort,
        debugName: 'foresight-domain',
      );
      spawned = true;
      await host._ready.future;
      return host;
    } catch (_) {
      host._control?.send('close');
      if (spawned) await host._workerExited.future;
      await host._finish();
      rethrow;
    }
  }

  void _message(dynamic message) {
    if (message is SendPort) {
      _control = message;
      return;
    }
    final value = message as List;
    if (value.first == 'ready') {
      _workerPath = value[1] as String;
      _publicPath = value[2] as String;
      final listening = _listen();
      _listening = listening;
      unawaited(
        listening.then(
          (_) {
            if (!_ready.isCompleted) _ready.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!_ready.isCompleted) _ready.completeError(error, stack);
          },
        ),
      );
    } else if (value.first == 'draining') {
      _traceServiceTransport('worker draining received');
      _workerClosing = true;
      _draining = true;
    } else if (value.first == 'closing') {
      _traceServiceTransport('worker ownership closing received');
      unawaited(
        _removePublicSocket(workerOwnsLock: true).then(
          (_) => _control?.send('frontend_closed'),
          onError: (Object error) {
            _failure ??= error;
            _control?.send('frontend_failed');
          },
        ),
      );
    } else if (value.first == 'failure') {
      _traceServiceTransport('worker failure received ${value[1]}');
      _failure = value.length > 2 && value[2] == true
          ? ServiceOwnershipContended(value[1] as String)
          : StateError(value[1] as String);
      if (!_ready.isCompleted) _ready.completeError(_failure!);
    }
  }

  Future<void> _listen() async {
    final path = _publicPath!;
    _traceServiceTransport('frontend bind $path');
    // The domain worker already holds both ownership locks, so a competing
    // launcher of this profile cannot remove the live owner's socket or
    // endpoint record, and a socket that still accepts here belongs to
    // another profile.
    await _clearStaleSocket(path);
    final binding = await ServiceSocketBinding.bind(path);
    _binding = binding;
    if (_publicClosing) {
      await binding.close();
      throw StateError('Service closed before socket publication');
    }
    await _publish(binding, _accept);
    _traceServiceTransport('frontend listening ${binding.identity}');
  }

  void _accept(Socket client) {
    if (_draining) {
      _refuse(client);
      return;
    }
    final bridge = _bridge(client);
    _bridges.add(bridge);
    unawaited(bridge.whenComplete(() => _bridges.remove(bridge)));
  }

  Future<void> _bridge(Socket client) async {
    final peer = identityHashCode(client);
    _traceServiceTransport('frontend accept peer=$peer');
    _peers.add(client);
    Socket? backend;
    try {
      _traceServiceTransport(
        'frontend backend connect peer=$peer $_workerPath',
      );
      backend = await Socket.connect(
        InternetAddress(_workerPath!, type: InternetAddressType.unix),
        0,
      );
      _traceServiceTransport('frontend backend connected peer=$peer');
      _peers.add(backend);
      if (_draining) {
        // The worker began closing while this connected; nothing was sent.
        backend.destroy();
        _peers.remove(client);
        _refuse(client);
        return;
      }
      // pipe applies stream backpressure and flushes before closing. Keeping
      // both directions alive is necessary for approval and cancel frames.
      Future<void> copy(Socket source, Socket target, String direction) async {
        try {
          Stream<List<int>> chunks = source.cast<List<int>>();
          if (runtimeConfiguration['FORESIGHT_SERVICE_TRACE'] == '1') {
            var first = true;
            chunks = chunks.map((chunk) {
              if (first) {
                first = false;
                _traceServiceTransport(
                  'frontend first bytes peer=$peer direction=$direction '
                  'length=${chunk.length}',
                );
              }
              return chunk;
            });
          }
          await target.addStream(chunks);
          await target.flush();
        } finally {
          _traceServiceTransport('frontend copy closed peer=$peer $direction');
          // Socket.close only half-closes its write side. Once either peer
          // reaches EOF, flush that direction and release both read sides.
          source.destroy();
          target.destroy();
        }
      }

      await Future.wait<void>([
        copy(client, backend, 'to-worker'),
        copy(backend, client, 'from-worker'),
      ]);
    } catch (error) {
      _traceServiceTransport('frontend bridge failed peer=$peer $error');
      backend?.destroy();
      if (backend == null && _draining) {
        // A closing worker no longer accepts; this client sent nothing yet.
        _peers.remove(client);
        _refuse(client);
      } else {
        client.destroy();
      }
    } finally {
      _peers.remove(client);
      if (backend != null) _peers.remove(backend);
    }
  }

  /// Answer every request on [client] with the closing refusal instead of
  /// bridging it, until the public socket is removed. A launcher waits for
  /// this connection's EOF before it probes the profile lock.
  void _refuse(Socket client) {
    if (_refusalsEnded) {
      client.destroy();
      return;
    }
    final peer = identityHashCode(client);
    _traceServiceTransport('frontend refuse peer=$peer');
    _refused.add(client);
    unawaited(client.done.catchError((Object _) {}));
    final frames = _FrameSplitter(maxServiceMessage);
    void stop() {
      _refused.remove(client);
      client.destroy();
    }

    client.listen(
      (chunk) {
        final complete = frames.add(chunk);
        if (complete == null) {
          stop();
          return;
        }
        for (final frame in complete) {
          final request = _decodeFrame(frame);
          final id = request?['id'];
          if (request == null || (id is! int && request['cancel'] is! int)) {
            _traceServiceTransport('frontend refused malformed peer=$peer');
            stop();
            return;
          }
          // Nothing was dispatched, so there is nothing to cancel.
          if (id is! int) continue;
          try {
            client.add(
              utf8.encode(
                '${jsonEncode({'id': id, 'error': _closingRefusal().toJson(), 'done': true})}\n',
              ),
            );
          } catch (_) {
            stop();
            return;
          }
        }
      },
      onError: (Object _) => stop(),
      onDone: stop,
      cancelOnError: true,
    );
  }

  /// A worker that dies without closing leaves its sockets open with nobody
  /// reading them. Refuse new connections and end attached ones now: only
  /// this crash path gives clients a bare EOF.
  void _workerLost() {
    _traceServiceTransport('worker exited unexpectedly');
    _failure ??= StateError('Application worker exited unexpectedly');
    _draining = true;
    for (final peer in _peers.toList()) {
      peer.destroy();
    }
  }

  Future<void> close() => _shutdown ??= () async {
    _traceServiceTransport('frontend close closing=$_closing');
    if (!_closing) {
      _closing = true;
      // Attached clients keep their bridges: the worker answers each request
      // in flight with a terminal frame and refuses later ones before it
      // closes their connections. New connections are refused here.
      _draining = true;
      _control?.send('close');
    }
    await closed;
    if (_failure != null) throw _failure!;
  }();

  Future<void> _removePublicSocket({bool workerOwnsLock = false}) async {
    _traceServiceTransport('frontend remove socket owns_lock=$workerOwnsLock');
    _publicClosing = true;
    // Join startup before cleanup so a pending bind cannot publish afterwards.
    try {
      await _listening;
    } catch (_) {
      // Startup reports its original error through _ready.
    }
    await _binding?.close();
    _traceServiceTransport('frontend listener closed');
    try {
      if (_publicRemoved || _publicPath == null) return;
      // The public socket no longer accepts, but its path still exists.
      if (serviceGatesEnabled) await serviceGate('frontend.listener_closed');
      RandomAccessFile? ownership;
      if (!workerOwnsLock) {
        // An unexpected worker exit may release its lock before this isolate
        // processes the exit message. A new process can already own the
        // profile. Reacquire ownership before touching its public socket path.
        try {
          _traceServiceTransport('frontend reacquiring ownership');
          ownership = await File(
            '$_dataPath/.application.lock',
          ).open(mode: FileMode.append);
          ownership.lockSync(FileLock.exclusive);
          _traceServiceTransport('frontend ownership reacquired');
        } on FileSystemException {
          await ownership?.close();
          return;
        }
      }
      try {
        // Unlink only the socket this frontend published. A replacement, or
        // an owner in this process or of another profile sharing the runtime
        // directory, may own the path now.
        final removed = await _binding?.unpublish() ?? false;
        _traceServiceTransport(
          removed
              ? 'frontend socket removed $_publicPath'
              : 'frontend leaves $_publicPath to its owner',
        );
        _publicRemoved = true;
      } finally {
        await ownership?.close();
      }
    } finally {
      // Refused clients wait for this EOF before probing the profile lock.
      // A bridge that fails later must not leave a new refusal open.
      _refusalsEnded = true;
      for (final client in _refused.toList()) {
        client.destroy();
      }
      _refused.clear();
    }
  }

  Future<void> _finish() => _finishing ??= _finishOnce();
  Future<void> _finishOnce() async {
    _traceServiceTransport('frontend finish begin');
    if (_closed.isCompleted) return;
    // The worker has exited. New clients are refused until the public socket
    // is gone, if the worker did not already release it.
    _draining = true;
    if (serviceGatesEnabled) await serviceGate('frontend.draining');
    try {
      await _removePublicSocket();
      // The worker flushes an idle-stop acknowledgement before exiting.
      await Future.wait(_bridges.toList()).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      for (final peer in _peers.toList()) {
        peer.destroy();
      }
    } catch (error) {
      _failure ??= error;
      for (final peer in _peers.toList()) {
        peer.destroy();
      }
    } finally {
      _messages.close();
      _errors.close();
      _exits.close();
      if (!_closed.isCompleted) _closed.complete();
    }
  }
}

void _applicationServiceWorker(List<Object?> configuration) {
  runApplicationWorkerZone(() async {
    try {
      await _runApplicationServiceWorker(configuration);
    } catch (error, stack) {
      // Include failures before the main worker lifecycle installs its own
      // handler (for example while installing the inherited environment).
      (configuration[0] as SendPort).send(['failure', '$error\n$stack']);
    }
  });
}

/// Keep recoverable asynchronous errors local to the worker. Startup and main
/// lifecycle failures are reported by the worker's failure message; uncaught
/// fatal isolate errors still reach Isolate.spawn's separate onError port.
void runApplicationWorkerZone(Future<void> Function() worker) {
  // ignore: discarded_futures
  runZonedGuarded(worker, (error, stack) {
    stderr.writeln('Application worker asynchronous error: $error\n$stack');
  });
}

Future<void> _runApplicationServiceWorker(List<Object?> configuration) async {
  final parent = configuration[0] as SendPort;
  installServiceWorkerEnvironment(
    (configuration[3] as Map).cast<String, String>(),
  );
  _traceServiceTransport('worker starting');
  final control = ReceivePort();
  parent.send(control.sendPort);
  ApplicationService? service;
  final stop = Completer<void>();
  final frontendClosed = Completer<void>();
  control.listen((message) {
    if (message == 'frontend_closed') {
      if (!frontendClosed.isCompleted) frontendClosed.complete();
    } else if (message == 'frontend_failed') {
      if (!frontendClosed.isCompleted) {
        frontendClosed.completeError(
          StateError('Public service socket cleanup failed'),
        );
      }
    } else if (!stop.isCompleted) {
      stop.complete();
    }
  });
  try {
    final profile = ProfilePaths(
      configuration[1] as String,
      configuration[2] as String,
    );
    service = await ApplicationService.start(profile, internalWorker: true);
    _traceServiceTransport('worker ready ${service.path}');
    service._onDraining = () => parent.send(['draining']);
    service._beforeReleaseOwnership = () {
      parent.send(['closing']);
      return frontendClosed.future;
    };
    // The public socket belongs beside the worker socket, in the runtime this
    // start created or adopted. Reading the record again could disagree.
    parent.send([
      'ready',
      service.path,
      '${File(service.path).parent.path}/application.sock',
    ]);
    await Future.any([stop.future, service.closed]);
    _traceServiceTransport('worker close begin');
    await service.close();
    _traceServiceTransport('worker close complete');
    // Let an idle-stop request flush its final acknowledgement after close.
    await Future<void>.delayed(Duration.zero);
  } catch (error, stack) {
    _traceServiceTransport('worker main failed $error\n$stack');
    parent.send([
      'failure',
      '$error\n$stack',
      error is ServiceOwnershipContended,
    ]);
    try {
      await service?.close();
    } catch (_) {}
  } finally {
    _traceServiceTransport('worker main finally');
    control.close();
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

/// Whether [path] names a startup status file in [profile]'s runtime.
bool _isStartupStatusPath(String path, ProfilePaths profile) =>
    _startupStatusName.hasMatch(_entryName(path)) &&
    canonicalProfilePath(File(path).parent.path) == profile.runtime;

/// Whether this service's launcher has stopped waiting for it. The launcher
/// creates FORESIGHT_STARTUP_STATUS before launching and deletes it when it
/// returns, so a missing file is a withdrawn lease. A launcher attaches only
/// to the lock holder, so a launch that holds the lock while its lease is
/// still there is the owner its launcher waits for. Starts without a lease,
/// such as direct starts, are unaffected.
bool _launchLeaseWithdrawn(ProfilePaths profile) {
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
        .call(Operation.status.wire, args)
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
    final value = Map<String, dynamic>.from(reply as Map);
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
        error is! _ServiceTransportLost);

bool _profileOwnerAvailable(
  ProfilePaths profile, {
  required bool closingOwner,
}) {
  final key = Directory(profile.data).resolveSymbolicLinksSync();
  if (_localServiceOwners.containsKey(key)) return false;
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
  if (!_profileLockFree(path)) return false;
  // A record without a lock owner means the previous owner exited
  // uncleanly. The replacement adopts that record's runtime in _start, or
  // sets the record aside if it is invalid.
  if (FileSystemEntity.typeSync(
        '${profile.data}/.application-endpoint.json',
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound) {
    _traceServiceTransport(
      'previous owner left its endpoint record; the replacement adopts its runtime',
    );
  }
  return true;
}

/// Whether a failed lockSync means another process holds the lock. F_SETLK
/// may report contention as EACCES or EAGAIN/EWOULDBLOCK (35 on macOS).
bool _lockContended(FileSystemException error) =>
    const {11, 13, 35}.contains(error.osError?.errorCode);

/// Whether no other process holds the profile lock at [path]. Only call this
/// from a process that hosts no owner of the profile: POSIX record locks
/// belong to the process, and closing this probe's descriptor drops them all.
/// Callers that check [_localServiceOwners] first are safe only in the
/// isolate that started the owner; another isolate does not see it there.
bool _profileLockFree(String path) {
  // Keep this probe synchronous: opening and closing another descriptor must
  // not interleave with a local owner.
  final ownership = File(path).openSync(mode: FileMode.append);
  try {
    ownership.lockSync(FileLock.exclusive);
    return true;
  } on FileSystemException catch (error) {
    // This catch only covers lockSync; opening an inaccessible file still
    // fails.
    if (_lockContended(error)) return false;
    rethrow;
  } finally {
    ownership.closeSync();
  }
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
  final lock = '${profile.data}/.application.lock';
  final waited = Stopwatch()..start();
  var held = false;
  while (true) {
    if ((ownerPid != null && !await _processRunning(ownerPid)) ||
        FileSystemEntity.typeSync(lock, followLinks: false) ==
            FileSystemEntityType.notFound ||
        _profileLockFree(lock)) {
      return true;
    }
    if (!held) {
      held = true;
      _traceServiceTransport(
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

/// Whether the profile has no owner but still has an endpoint record: the
/// last owner did not shut down cleanly, and the next one recovers its
/// runtime. Never call this from a process that hosts an owner of the
/// profile, in any isolate: it probes the lock, POSIX record locks belong to
/// the process, and closing the probe's descriptor drops the owner's lock.
bool profileLeftUnclean(ProfilePaths profile) {
  final lock = '${profile.data}/.application.lock';
  return FileSystemEntity.typeSync(
            '${profile.data}/$_endpointRecordName',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound &&
      (FileSystemEntity.typeSync(lock, followLinks: false) ==
              FileSystemEntityType.notFound ||
          _profileLockFree(lock));
}

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
  for (final path in _endpointEntries(runtime, _startupStatusEntry)) {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (type == FileSystemEntityType.file &&
              File(path).lastModifiedSync().isBefore(cutoff))) {
        _deleteEndpointEntry(path);
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
  String? executable;
  String? startupLog;
  File? handoff;
  // Where the latest launch records a start that did not happen.
  File? startupStatus;
  String? ignoredRecord;
  // Why this profile's endpoint record names another profile's service.
  String? staleRecord;
  // Endpoints whose service this startup found to be another profile's.
  final refused = <String>{};
  TimeoutException deadlineFailure() {
    final failure = launches > 0
        ? startupLog != null
              ? 'Application service did not start. Inspect $startupLog.'
              : 'Application service did not start. Run $executable directly to inspect the startup error.'
        : staleRecord ??
              (closingOwner
                  ? 'Application service owner handoff did not finish'
                  : 'Application service profile lock is still held; its owner is not serving the endpoint.');
    return TimeoutException(
      ignoredRecord == null
          ? failure
          : '${failure.endsWith('.') ? failure : '$failure.'} The endpoint '
                'record ${profile.data}/$_endpointRecordName was ignored '
                'because $ignoredRecord.',
    );
  }

  Duration remaining() {
    final left = startupTimeout - startup.elapsed;
    if (left <= Duration.zero) throw deadlineFailure();
    return left;
  }

  Future<void> launchOnce() async {
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
        _traceServiceTransport(message);
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
      } on _ServiceTransportLost {
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
        await launchOnce();
      }
      switch (startupStatus == null
          ? null
          : _recordedStartupOutcome(startupStatus!)) {
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
          await _deleteLaunchFiles(startupStatus, handoff);
          launches++;
          await launchOnce();
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
    await _deleteLaunchFiles(startupStatus, handoff);
  }
}

/// Remove one launch's startup status and its unconsumed environment handoff.
Future<void> _deleteLaunchFiles(File? status, File? handoff) async {
  if (handoff != null && handoff.existsSync()) {
    await handoff.delete();
    await handoff.parent.delete();
  }
  if (status != null && status.existsSync()) await status.delete();
}
