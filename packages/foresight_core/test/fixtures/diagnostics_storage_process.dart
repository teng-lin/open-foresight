import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';

Future<void> main(List<String> arguments) async {
  final mode = arguments[0];
  if (mode == 'inherited') {
    final expected = arguments.skip(1).toSet();
    final inherited = <int>[];
    for (var fd = 10; fd < 256; fd++) {
      if (expected.contains(BackupFile.inspectDescriptorIdentity(fd))) {
        inherited.add(fd);
      }
    }
    stdout.writeln(jsonEncode(inherited));
    return;
  }
  final profile = arguments[1];
  if (mode == 'lease') {
    final directory = BackupDirectory(
      '$profile/logs/slot-${arguments[2]}',
      minimumDescriptor: 10,
    );
    final lease = directory.open('lease');
    try {
      stdout.writeln(jsonEncode({'acquired': lease.tryExclusiveLease()}));
    } finally {
      lease.close();
      directory.close();
    }
    return;
  }
  if (mode == 'blocked') {
    await _blocked(profile);
    return;
  }

  if (mode == 'mount-refusal') {
    _mountRefusal(profile);
    return;
  }

  final role = DiagnosticRole.values.byName(arguments[2]);
  if (mode == 'metrics') {
    final rssBefore = ProcessInfo.currentRss;
    final session = await LoggingSession.start(
      configuration: const DiagnosticConfiguration(),
      role: DiagnosticRole.transient,
    );
    final producers = [
      session.producer,
      for (var i = 1; i < LoggingSession.maximumProducers; i++)
        session.registerProducer(DiagnosticProducerKind.domain),
    ];
    await Future.wait(producers.map((producer) => producer.ready));
    final elapsed = Stopwatch()..start();
    var accepted = 0;
    for (final producer in producers) {
      for (var i = 0; i < 10000; i++) {
        if (producer.emit(
          DiagnosticEvent.serviceStarting,
          DiagnosticComponent.service,
        )) {
          accepted++;
        }
      }
      if (producer.emit(
        DiagnosticEvent.runtimeFailed,
        DiagnosticComponent.service,
      )) {
        accepted++;
      }
    }
    elapsed.stop();
    final close = await session.close();
    stdout.writeln(
      jsonEncode({
        'rss_before': rssBefore,
        'rss_after': ProcessInfo.currentRss,
        'peak_rss': ProcessInfo.maxRss,
        'emit_calls': 160016,
        'accepted': accepted,
        'elapsed_us': elapsed.elapsedMicroseconds,
        'writer_exited': close.writerExited,
        'charged_high_water_bytes': session.health.highWaterBytes,
        'record_high_water': session.health.highWaterRecords,
      }),
    );
    return;
  }
  if (mode == 'cold') {
    final session = await LoggingSession.start(
      configuration: const DiagnosticConfiguration(),
      profilePath: profile,
      role: role,
    );
    final ownership = session.expectOwnershipDecision();
    session.producer.emit(
      DiagnosticEvent.serviceStarting,
      DiagnosticComponent.service,
    );
    ownership.report(OwnershipDecision.values.byName(arguments[3]));
    final result = await session.close();
    stdout.writeln(jsonEncode({'exited': result.writerExited}));
    return;
  }
  final storage = DiagnosticStorage.admit(
    profile,
    DiagnosticIdentity.random(),
    role,
    ownedSlots: arguments.contains('shared') ? {0, 1, 2, 3, 4} : {},
  );
  if (storage == null) {
    stdout.writeln(jsonEncode({'slot': null}));
    return;
  }
  final failed = arguments.contains('failed');
  if (!storage.classify(
    role,
    error: failed || arguments.contains('warn'),
    genuineFailure: failed,
  )) {
    throw StateError('Fixture classification failed');
  }
  if (!storage.append(
    Uint8List.fromList(
      utf8.encode(
        '${jsonEncode({'schema': 1, 'event': 'service.ready', 'component': 'service', 'fields': <String, Object>{}})}\n',
      ),
    ),
  )) {
    throw StateError('Fixture append failed');
  }
  if (arguments.contains('fill')) {
    final record = Uint8List.fromList(
      utf8.encode('${jsonEncode({'schema': 1, 'fixture': 'x' * 15000})}\n'),
    );
    for (var i = 0; i < 400; i++) {
      if (!storage.append(record)) {
        throw StateError('Fixture quota fill failed');
      }
    }
  }
  if (mode == 'stdio') {
    final proof = storage.descriptorProof
        .map((fd) => {'descriptor': fd.descriptor, 'cloexec': fd.closeOnExec})
        .toList();
    File('$profile/fd-proof.json').writeAsStringSync(jsonEncode(proof));
    storage.close();
    return;
  }
  if (mode == 'quota') {
    final libc = DynamicLibrary.process();
    final setLimit = libc
        .lookupFunction<
          Int32 Function(Int32, Pointer<Uint64>),
          int Function(int, Pointer<Uint64>)
        >('setrlimit');
    final signal = libc
        .lookupFunction<
          Pointer<Void> Function(Int32, Pointer<Void>),
          Pointer<Void> Function(int, Pointer<Void>)
        >('signal');
    final allocate = libc
        .lookupFunction<
          Pointer<Void> Function(UintPtr),
          Pointer<Void> Function(int)
        >('malloc');
    final release = libc
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('free');
    final limit = allocate(16).cast<Uint64>();
    limit[0] = 8192;
    limit[1] = 8192;
    signal(25, Pointer<Void>.fromAddress(1));
    if (setLimit(1, limit) != 0) {
      throw StateError('Cannot set fixture size limit');
    }
    release(limit.cast<Void>());
    final record = Uint8List.fromList(
      utf8.encode('${jsonEncode({'schema': 1, 'fixture': 'x' * 6000})}\n'),
    );
    final first = storage.append(record);
    final second = storage.append(record);
    final third = storage.append(record);
    final failed = storage.failed;
    storage.close();
    stdout.writeln(
      jsonEncode({
        'first': first,
        'second': second,
        'third': third,
        'failed': failed,
        'slot': storage.slot,
      }),
    );
    return;
  }
  final proof = storage.descriptorProof;
  final child = await Process.run(Platform.resolvedExecutable, [
    'inherited',
    ...proof.map((value) => value.identity),
  ]);
  stdout.writeln(
    jsonEncode({
      'slot': storage.slot,
      'session': storage.session,
      'inherited': jsonDecode(child.stdout as String),
      'cloexec': proof.every((value) => value.closeOnExec),
      'minimum': proof
          .map((value) => value.descriptor)
          .reduce((a, b) => a < b ? a : b),
    }),
  );
  await stdout.flush();
  try {
    if (mode == 'hold') await stdin.drain<void>();
  } finally {
    storage.close();
  }
}

Future<void> _blocked(String profile) async {
  final native = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  if (native != null) DynamicLibrary.open(native);
  final entered = ReceivePort();
  final owner = entered.sendPort;
  final session = await LoggingSession.startForTesting(
    configuration: const DiagnosticConfiguration(),
    profilePath: profile,
    role: DiagnosticRole.desktop,
    sinkFactory: (path, identity, role) =>
        _BlockingSink(DiagnosticStorage.admit(path, identity, role)!, owner),
  );
  session.producer.emit(
    DiagnosticEvent.runtimeFailed,
    DiagnosticComponent.desktop,
  );
  final slot = await entered.first.timeout(const Duration(seconds: 2)) as int;
  entered.close();
  // Model required application/child cleanup and intentional output disposition
  // BEFORE the final logger budget. The foundation never calls exit itself.
  File('$profile/cleanup-complete').writeAsStringSync('complete');
  stdout.write('Content-Length: 2\r\n\r\n{}');
  stderr.write('intentional presentation\n');
  await stdout.flush();
  await stderr.flush();
  final elapsed = Stopwatch()..start();
  final result = await session.close();
  elapsed.stop();
  File('$profile/close-proof.json').writeAsStringSync(
    jsonEncode({
      'writer_exited': result.writerExited,
      'explicit_exit': result.requiresExplicitExit,
      'elapsed_ms': elapsed.elapsedMilliseconds,
      'slot': slot,
      'native_loaded': native != null,
    }),
  );
  if (result.requiresExplicitExit) exit(37);
  exitCode = 2;
}

final class _BlockingSink implements DiagnosticSink {
  _BlockingSink(this.inner, this.owner);
  final DiagnosticStorage inner;
  final SendPort owner;
  @override
  int get slot => inner.slot;
  @override
  bool get failed => inner.failed;
  @override
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  }) => inner.classify(role, error: error, genuineFailure: genuineFailure);
  @override
  bool append(Uint8List record) {
    inner.append(record);
    owner.send(slot);
    final libc = DynamicLibrary.process();
    // nfds_t differs between Linux x86-64 and Darwin arm64. Zero descriptors
    // and an infinite timeout reproduce a genuinely blocked synchronous FFI.
    final poll = Platform.isMacOS
        ? libc.lookupFunction<
            Int32 Function(Pointer<Void>, Uint32, Int32),
            int Function(Pointer<Void>, int, int)
          >('poll')
        : libc.lookupFunction<
            Int32 Function(Pointer<Void>, UintPtr, Int32),
            int Function(Pointer<Void>, int, int)
          >('poll');
    while (true) {
      poll(nullptr, 0, -1);
    }
  }

  @override
  void close() => inner.close();
}

// Explicit Linux namespace fixture. The caller supplies a private selected
// profile and invokes it through unshare --user --map-root-user --mount.
void _mountRefusal(String path) {
  final profile = BackupDirectory(path, create: false);
  final root = profile.child('logs');
  final mounted = root.child('slot-3');
  final mount = Process.runSync('/usr/bin/mount', [
    '-t',
    'tmpfs',
    '-o',
    'mode=700,size=1m',
    'tmpfs',
    mounted.path,
  ]);
  if (mount.exitCode != 0) {
    throw StateError('mount infrastructure: ${mount.stderr}');
  }
  final nested = BackupDirectory(mounted.path);
  final storage = DiagnosticStorage.admit(
    profile.path,
    DiagnosticIdentity.random(),
    DiagnosticRole.desktop,
    ownedSlots: {0, 1, 2, 4, 5, 6, 7, 8, 9},
  );
  final directoryRefused = storage == null;
  final source = File('${mounted.path}/foreign-file');
  source.writeAsBytesSync([]);
  Process.runSync('/usr/bin/chmod', ['600', source.path]);
  final admission = root.openOrCreate('admission.lock');
  admission.close();
  final bind = Process.runSync('/usr/bin/mount', [
    '--bind',
    source.path,
    '${root.path}/admission.lock',
  ]);
  if (bind.exitCode != 0) {
    throw StateError('bind infrastructure: ${bind.stderr}');
  }
  var fileRefused = false;
  try {
    DiagnosticStorage.admit(
      profile.path,
      DiagnosticIdentity.random(),
      DiagnosticRole.desktop,
    );
  } on DiagnosticStorageUnavailable catch (e) {
    fileRefused = e.reason == DiagnosticHealthReason.unsupportedFilesystem;
  }
  stdout.writeln(
    jsonEncode({
      'root': root.localFileSystem.name,
      'nested': nested.localFileSystem.name,
      'nested_slot_refused': directoryRefused,
      'mounted_admission_file_refused': fileRefused,
    }),
  );
  nested.close();
  mounted.close();
  root.close();
  profile.close();
  if (!directoryRefused || !fileRefused) exitCode = 1;
}
