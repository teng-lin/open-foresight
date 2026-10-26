import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/events.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_dispatch.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_native.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_protocol.dart';

import 'diagnostics_native_owner.dart' as operations;

// Explicit private fixture identity and loader. Product command/anchor/identity
// selection is separate: this file is never the installed worker entrypoint.
const identity = operations.identity;
void require(bool condition) {
  if (!condition) throw StateError('Diagnostic storage child fixture failed');
}

final class Channel {
  Channel(this.functions, this.id)
    : endpoint = DiagnosticNativeEndpoint(functions, id);
  final DiagnosticNativeFunctions functions;
  final int id;
  final DiagnosticNativeEndpoint endpoint;
  int next = 1;

  Future<Uint8List> _receive(int type, int request) async {
    final elapsed = Stopwatch()..start();
    final buffer = Uint8List(512);
    var offset = 0;
    while (elapsed.elapsed < const Duration(seconds: 3)) {
      final frame = endpoint.receive();
      require(frame.result != DiagnosticNativeFunctions.error);
      if (frame.result != DiagnosticNativeFunctions.empty) {
        require(offset + frame.bytes.length <= buffer.length);
        buffer.setRange(offset, offset + frame.bytes.length, frame.bytes);
        offset += frame.bytes.length;
      }
      if (frame.result == DiagnosticNativeFunctions.complete) {
        require(
          frame.type == type &&
              frame.request == request &&
              frame.total == offset,
        );
        return Uint8List.sublistView(buffer, 0, offset);
      }
      require(functions.heartbeat(id) == 0);
      require(functions.poll(id) >= 0);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    throw StateError('Diagnostic storage reply deadline');
  }

  Future<void> hello() async {
    require((await _receive(1, 0)).isEmpty);
    final elapsed = Stopwatch()..start();
    while (true) {
      final status = functions.poll(id);
      require(status >= 0);
      if (status & DiagnosticNativeFunctions.watchBound != 0) return;
      require(elapsed.elapsed < const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<DiagnosticWorkerReply> request(int type, Uint8List bytes) async {
    require(bytes.length <= 8192);
    final request = next++;
    var offset = 0;
    while (true) {
      final count = (bytes.length - offset).clamp(
        0,
        DiagnosticNativeFunctions.chunkBytes,
      );
      final result = endpoint.send(
        type,
        request,
        bytes.length,
        Uint8List.sublistView(bytes, offset, offset + count),
      );
      require(
        result == DiagnosticNativeFunctions.partial ||
            result == DiagnosticNativeFunctions.complete,
      );
      offset += count;
      if (result == DiagnosticNativeFunctions.complete) break;
    }
    require(offset == bytes.length);
    return DiagnosticWorkerReply.decode(
      await _receive(type == 8 ? 9 : 3, request),
    );
  }
}

Future<void> parent(List<String> arguments) async {
  // parent,support,launcher,worker-exe,[worker-argv...],profile,scenario
  require(arguments.length >= 6);
  final profile = arguments[arguments.length - 2], scenario = arguments.last;
  require(const {'normal', 'oversize', 'max-init'}.contains(scenario));
  final functions = DiagnosticNativeFunctions.fromImage(
    DynamicLibrary.open(arguments[1]),
  );
  final command = [
    arguments[2],
    identity,
    '$pid',
    ...arguments
        .sublist(3, arguments.length - 2)
        .map(
          (value) =>
              value == '@disable-dart-dev' ? '--disable-dart-dev' : value,
        ),
    '--diagnostic-storage-worker',
    '$pid',
    '--diagnostic-native-support',
    arguments[1],
  ];
  final id = functions.reserve(
    nativeId: identity,
    dartId: identity,
    catalogId: identity,
    arguments: command,
  );
  require(id == 1);
  require(await operations.runOperation(functions, id, prepare: true) == 2);
  require(await operations.runOperation(functions, id, prepare: false) == 8);
  final channel = Channel(functions, id);
  final session = DiagnosticIdentity.random();
  final empty = Uint8List(0);
  int? slot;
  try {
    await channel.hello();
    final init = DiagnosticWorkerInit(
      profile: scenario == 'max-init' ? '/${'\u0001' * 4095}' : profile,
      session: session,
      role: DiagnosticRole.candidate,
    ).encode();
    require(
      (await channel.request(2, init)).result == DiagnosticWorkerResult.ok,
    );
    if (scenario == 'max-init') {
      require(init.length == 4122);
      require(
        (await channel.request(7, empty)).result == DiagnosticWorkerResult.ok,
      );
    } else {
      final admitted = await channel.request(4, empty);
      require(
        admitted.result == DiagnosticWorkerResult.ok && admitted.slot != null,
      );
      slot = admitted.slot;
      require(
        (await channel.request(
              5,
              const DiagnosticWorkerClassification(
                DiagnosticRole.service,
                error: true,
                genuineFailure: true,
              ).encode(),
            )).result ==
            DiagnosticWorkerResult.ok,
      );
      for (var sequence = 1; sequence <= 2; ++sequence) {
        final event = sequence == 1
            ? DiagnosticEvent.serviceReady
            : DiagnosticEvent.runtimeFailed;
        final record = Uint8List.fromList(
          utf8.encode(
            '${jsonEncode({'schema': 2, 'timestamp': DateTime.now().toUtc().toIso8601String(), 'sequence': sequence, 'level': event.severity.name, 'version': '0.0.0-fixture', 'revision': 'unknown', 'session': session.value, 'pid': pid, 'producer': 'entrypoint:0:1', 'build_id': identity, 'event': event.wire, 'component': 'service', 'fields': <String, Object>{}})}\n',
          ),
        );
        require(
          (await channel.request(6, record)).result ==
              DiagnosticWorkerResult.ok,
        );
      }
      if (scenario == 'oversize') {
        final body = Uint8List(8192)
          ..fillRange(0, 8191, 120)
          ..[8191] = 10;
        // The native boundary rejects oversize APPEND BEFORE publication and
        // poisons this endpoint. Independent FORCE still retires the child.
        require(
          channel.endpoint.send(
                6,
                channel.next,
                body.length,
                Uint8List.sublistView(
                  body,
                  0,
                  DiagnosticNativeFunctions.chunkBytes,
                ),
              ) ==
              DiagnosticNativeFunctions.error,
        );
        require(functions.force(id) == DiagnosticNativeFunctions.cancelled);
      }
    }
    if (scenario != 'oversize') {
      final retired = await channel.request(8, empty);
      require(
        retired.result == DiagnosticWorkerResult.ok &&
            retired.reason == DiagnosticHealthReason.closed,
      );
    }
    final elapsed = Stopwatch()..start();
    while (true) {
      final status = functions.poll(id);
      require(status >= 0);
      if (status & DiagnosticNativeFunctions.notLive != 0) break;
      require(elapsed.elapsed < const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (Platform.isLinux) {
      require(functions.exitClass(id) == (scenario == 'oversize' ? 66 : 1));
    }
    // Explicit filesystem observer fixture AFTER the child retired; these reads
    // are not application-PID logging or product support-folder code.
    if (slot != null) {
      final records = File(
        '$profile/logs/slot-$slot/0.jsonl',
      ).readAsLinesSync();
      require(records.length == 2);
      for (var index = 0; index != records.length; ++index) {
        final value = jsonDecode(records[index]) as Map;
        require(
          value['schema'] == 2 &&
              value['build_id'] == identity &&
              value['pid'] == pid &&
              value['sequence'] == index + 1 &&
              value['session'] == session.value,
        );
      }
    } else {
      require(!Directory('$profile/logs').existsSync());
    }
    stdout.writeln(
      jsonEncode({
        'scenario': scenario,
        'stored': slot == null ? 0 : 2,
        'no_live_child': true,
        'exit_class': functions.exitClass(id),
      }),
    );
  } finally {
    functions.force(id);
    channel.endpoint.close();
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.firstOrNull == '--diagnostic-storage-worker') {
    if (arguments.length != 4 ||
        arguments[2] != '--diagnostic-native-support' ||
        int.tryParse(arguments[1]) == null ||
        !arguments[3].startsWith('/')) {
      exit(64);
    }
    final functions = DiagnosticNativeFunctions.fromImage(
      DynamicLibrary.open(arguments[3]),
    );
    exit(
      await runDiagnosticStorageWorker(
        functions: functions,
        expectedParentPid: int.parse(arguments[1]),
        nativeId: identity,
        dartId: identity,
        catalogId: identity,
      ),
    );
  }
  require(arguments.firstOrNull == '--parent');
  await parent(arguments);
}
