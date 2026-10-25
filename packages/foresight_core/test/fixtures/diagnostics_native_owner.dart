import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/storage_worker_native.dart';

// Explicit private fixture identity. This executable is not a product selector
// and does not establish a source/installation command-validation gate.
const identity =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void require(bool condition) {
  if (!condition) throw StateError('Diagnostic owner fixture failed');
}

void nativeOperation((List<int>, int, bool, SendPort) arguments) {
  final (addresses, id, prepare, reply) = arguments;
  final functions = DiagnosticNativeFunctions.fromCodeAddresses(addresses);
  reply.send(prepare ? functions.prepare(id) : functions.spawn(id));
}

Future<int> runOperation(
  DiagnosticNativeFunctions functions,
  int id, {
  required bool prepare,
}) async {
  final result = ReceivePort();
  final exited = ReceivePort();
  final errors = ReceivePort();
  try {
    final terminal = exited.first;
    final returned = result.first;
    // Only code addresses/opaque ID/control ports cross into the operation.
    // Actual exit is awaited separately from its success message.
    await Isolate.spawn(
      nativeOperation,
      (functions.codeAddresses, id, prepare, result.sendPort),
      onExit: exited.sendPort,
      onError: errors.sendPort,
      errorsAreFatal: true,
    );
    final value = await returned.timeout(const Duration(seconds: 3));
    await terminal.timeout(const Duration(seconds: 1));
    return value as int;
  } finally {
    result.close();
    exited.close();
    errors.close();
  }
}

void watch((List<int>, int, SendPort) arguments) {
  final (addresses, id, reply) = arguments;
  final functions = DiagnosticNativeFunctions.fromCodeAddresses(addresses);
  require(functions.watch(id) == 0);
  reply.send(true);
  Timer.periodic(const Duration(milliseconds: 100), (_) {
    require(functions.watch(id) == 0);
  });
}

Future<void> receive(
  DiagnosticNativeEndpoint endpoint,
  int expectedType,
  int expectedId, {
  bool parent = false,
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 3)) {
    final frame = endpoint.receive();
    require(frame.result != DiagnosticNativeFunctions.error);
    if (frame.result == DiagnosticNativeFunctions.complete) {
      require(frame.type == expectedType && frame.request == expectedId);
      if (expectedType == 2 || expectedType == 3) {
        require(frame.total == 4 && utf8.decode(frame.bytes) == 'test');
      } else {
        require(frame.total == 0 && frame.bytes.isEmpty);
      }
      return;
    }
    if (parent) {
      require(endpoint.functions.heartbeat(endpoint.id) == 0);
      require(endpoint.functions.poll(endpoint.id) >= 0);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw StateError('Diagnostic owner fixture receive deadline');
}

Future<void> child(List<String> arguments) async {
  require(arguments.length == 4);
  final image = DynamicLibrary.open(arguments[2]);
  final functions = DiagnosticNativeFunctions.fromImage(image);
  final id = functions.armChild(
    parentPid: int.parse(arguments[1]),
    nativeId: identity,
    dartId: identity,
    catalogId: identity,
  );
  require(id == 1);
  final armed = ReceivePort();
  final errors = ReceivePort();
  try {
    final ack = armed.first;
    await Isolate.spawn(
      watch,
      (functions.codeAddresses, id, armed.sendPort),
      onError: errors.sendPort,
      errorsAreFatal: true,
    );
    require(await ack.timeout(const Duration(seconds: 1)) == true);
  } finally {
    armed.close();
    errors.close();
  }
  require(functions.mapChild(id) == DiagnosticNativeFunctions.prepared);
  final endpoint = DiagnosticNativeEndpoint(functions, id);
  require(endpoint.send(1, 0, 0, Uint8List(0)) == 2);
  await receive(endpoint, 2, 1);
  if (arguments[3] != 'normal') {
    // The native call publishes RESULT before holding this isolate in FFI.
    // A separate Dart isolate must retire the entire process while it is held.
    final held = image
        .lookupFunction<Int32 Function(Uint64), int Function(int)>(
          'fs_diag_fixture_held_result',
        );
    held(id);
    throw StateError('Held FFI unexpectedly returned');
  }
  require(endpoint.send(3, 1, 4, Uint8List.fromList(utf8.encode('test'))) == 2);
  await receive(endpoint, 8, 2);
  // All file cleanup would precede RETIRED in the actual storage worker.
  require(endpoint.send(9, 2, 0, Uint8List(0)) == 2);
  endpoint.close();
  exit(0);
}

Future<void> parent(List<String> arguments) async {
  // parent,support,launcher,worker-executable,[worker-argv...],mode
  require(arguments.length >= 5);
  final mode = arguments.last;
  require(const {'normal', 'force', 'deadline'}.contains(mode));
  final image = DynamicLibrary.open(arguments[1]);
  final functions = DiagnosticNativeFunctions.fromImage(image);
  final command = [
    arguments[2],
    identity,
    '$pid',
    // Dart3.9.2 rejects a literal --disable-dart-dev even among SCRIPT
    // arguments. This fixture marker expands only when constructing the child
    // VM command; the child receives the actual VM flag before its script.
    ...arguments
        .sublist(3, arguments.length - 1)
        .map(
          (value) =>
              value == '@disable-dart-dev' ? '--disable-dart-dev' : value,
        ),
    '--worker',
    '$pid',
    arguments[1],
    mode,
  ];
  final id = functions.reserve(
    nativeId: identity,
    dartId: identity,
    catalogId: identity,
    arguments: command,
  );
  require(id == 1);
  require(await runOperation(functions, id, prepare: true) == 2);
  require(await runOperation(functions, id, prepare: false) == 8);
  final endpoint = DiagnosticNativeEndpoint(functions, id);
  try {
    await receive(endpoint, 1, 0, parent: true);
    final binding = Stopwatch()..start();
    while (true) {
      final status = functions.poll(id);
      require(status >= 0);
      if ((status & DiagnosticNativeFunctions.watchBound) != 0) break;
      require(binding.elapsed < const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    require(
      endpoint.send(2, 1, 4, Uint8List.fromList(utf8.encode('test'))) == 2,
    );
    await receive(endpoint, 3, 1, parent: true);
    final retirement = Stopwatch()..start();
    if (mode == 'force') {
      require(functions.force(id) == DiagnosticNativeFunctions.cancelled);
    } else if (mode == 'normal') {
      require(endpoint.send(8, 2, 0, Uint8List(0)) == 2);
      await receive(endpoint, 9, 2, parent: true);
    }
    var status = 0;
    while (true) {
      status = functions.poll(id);
      require(status >= 0);
      if ((status & DiagnosticNativeFunctions.notLive) != 0) break;
      require(
        retirement.elapsed <
            (mode == 'deadline'
                ? const Duration(seconds: 6)
                : const Duration(milliseconds: 500)),
      );
      // The active-operation deadline must expire despite live heartbeats.
      require(functions.heartbeat(id) == 0);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (Platform.isLinux) {
      require((status & DiagnosticNativeFunctions.reaped) != 0);
      require(functions.exitClass(id) == (mode == 'normal' ? 1 : 66));
    } else {
      require((status & DiagnosticNativeFunctions.reaped) == 0);
      require(functions.exitClass(id) == 0);
    }
    stdout.writeln(
      jsonEncode({
        'mode': mode,
        'no_live_child': true,
        'reaped': (status & DiagnosticNativeFunctions.reaped) != 0,
        'exit_class': functions.exitClass(id),
        'retirement_ms': retirement.elapsedMilliseconds,
      }),
    );
  } finally {
    functions.force(id);
    endpoint.close();
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.firstOrNull == '--worker') {
    await child(arguments);
  } else {
    require(arguments.firstOrNull == '--parent');
    await parent(arguments);
  }
}
