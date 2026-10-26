// Real native queue -> production NativeRuntime -> writer -> exec storage child.
// The explicit false-executable capture route exercises a real worker/owned
// child without a microphone, audio device, permission prompt or model.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_native.dart';
import 'package:foresight_core/src/native.dart';

import 'diagnostics_owner_ffi.dart' show identity;

void require(bool value, String reason) {
  if (!value) throw StateError(reason);
}

Future<void> until(FutureOr<bool> Function() condition) async {
  final elapsed = Stopwatch()..start();
  while (!await condition()) {
    require(
      elapsed.elapsed < const Duration(seconds: 10),
      'Native diagnostic application deadline',
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

List<Map> records(String profile) => [
  if (Directory('$profile/logs').existsSync())
    for (final slot in Directory(
      '$profile/logs',
    ).listSync().whereType<Directory>())
      for (final file in slot.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.jsonl'),
      ))
        for (final line in file.readAsLinesSync())
          if (line.isNotEmpty) jsonDecode(line) as Map,
];

Future<void> main(List<String> arguments) async {
  require(arguments.length == 4, 'Native diagnostic application arguments');
  final native = arguments[0],
      support = arguments[1],
      launcher = arguments[2],
      profile = arguments[3];
  final functions = DiagnosticNativeFunctions.fromImage(
    DynamicLibrary.open(support),
  );
  NativeDiagnosticWorkerOwner? owner;
  final configuration = DiagnosticConfiguration.fromEnvironment(
    Platform.environment,
  );
  final session = await LoggingSession.start(
    configuration: configuration,
    profilePath: profile,
    workerFactory: (context) => owner = NativeDiagnosticWorkerOwner(
      context,
      functions,
      resolveCommand: () => DiagnosticStorageCommand(
        nativeId: identity,
        dartId: identity,
        catalogId: identity,
        arguments: [
          launcher,
          identity,
          '$pid',
          Platform.resolvedExecutable,
          '--disable-dart-dev',
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          File('test/fixtures/diagnostics_storage_child.dart').absolute.path,
          '--diagnostic-storage-worker',
          '$pid',
          '--diagnostic-native-support',
          support,
        ],
      ),
    ),
  );
  session.expectOwnershipDecision().report(OwnershipDecision.acquired);
  final runtime = NativeRuntime(native);
  final image = runtime.lib;
  final target = 'auto'.toNativeUtf8();
  Pointer<Void> capture = nullptr;
  LoggingCloseResult? closed;
  try {
    capture = image
        .lookupFunction<
          Pointer<Void> Function(Pointer<Utf8>, Int32, Int32),
          Pointer<Void> Function(Pointer<Utf8>, int, int)
        >('fs_capture_start')(target, 0, 8000);
    require(capture != nullptr, 'Actual capture worker admission failed');
    await until(
      () => records(profile).any((r) => r['event'] == 'native.worker_failed'),
    );
    image.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)
    >('fs_capture_finish')(capture);
    image.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)
    >('fs_capture_stop')(capture);
    capture = nullptr;
    closed = await session.close();
    require(
      closed.writerExited && closed.ownerSettled && closed.flushed,
      'Native diagnostic application close was not confirmed',
    );
    require(
      owner != null &&
          owner!.snapshot.childNotLive &&
          owner!.snapshot.parentSettled,
      'Actual diagnostic child still owned',
    );
    final persisted = records(profile);
    require(persisted.isNotEmpty, 'Actual storage child wrote no records');
    var previous = 0;
    for (final record in persisted) {
      require(
        record['schema'] == 2 &&
            record['pid'] == pid &&
            record['build_id'] == identity,
        'Actual schema2 identity mismatch',
      );
      require(
        (record['sequence'] as int) > previous,
        'Final writer sequence regressed',
      );
      previous = record['sequence'] as int;
    }
    final failed = persisted
        .where((r) => r['event'] == 'native.worker_failed')
        .toList();
    require(
      failed.any(
        (r) =>
            (r['producer'] as String).startsWith('nativeDrain:') &&
            (r['fields'] as Map)['status'] != 0,
      ),
      'Actual native retry failure did not reach storage',
    );
    final manifests = Directory('$profile/logs')
        .listSync()
        .whereType<Directory>()
        .map((d) => File('${d.path}/manifest.json'))
        .where((f) => f.existsSync())
        .map((f) => jsonDecode(f.readAsStringSync()) as Map);
    require(
      manifests.any(
        (m) =>
            m['role'] == 'service' &&
            m['has_error'] == true &&
            (m['failure_order'] as int) > 0,
      ),
      'Actual service failure was not protected',
    );
    final key = 'FORESIGHT_LOG_LEVEL'.toNativeUtf8();
    late String installed;
    try {
      final value = DynamicLibrary.process()
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)
          >('getenv')(key);
      installed = value == nullptr ? 'missing' : value.toDartString();
    } finally {
      calloc.free(key);
    }
    require(
      installed == configuration.level.name,
      'Native canonical level was not installed',
    );
    stdout.writeln(
      jsonEncode({
        'actual_native_runtime': true,
        'actual_capture_child': true,
        'actual_storage_child': true,
        'schema': 2,
        'records': persisted.length,
        'native_failures': failed.length,
        'writer_exited': closed.writerExited,
        'owner_settled': closed.ownerSettled,
        'flushed': closed.flushed,
        'native_level': installed,
        'transport_trace': configuration.transportTrace,
        'invalid_level': configuration.invalidLevel,
        'native_health': session.health.nativeReason.name,
      }),
    );
  } finally {
    calloc.free(target);
    if (capture != nullptr) {
      image.lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('fs_capture_finish')(capture);
      image.lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('fs_capture_stop')(capture);
    }
    if (closed == null) await session.close();
  }
}
