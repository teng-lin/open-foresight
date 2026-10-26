import 'sql_support_test_bootstrap.dart';
import 'support/diagnostic_child_exit_probe.dart';
import 'package:foresight_test_support/desktop_identity.dart';
import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:foresight_test_support/capture_process.dart';
import 'package:foresight_test_support/hooked_service.dart'
    show ServiceGates, sourceServiceCompileDefines;
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/diagnostics/events.dart'
    show DiagnosticRecord;
import 'package:foresight_core/src/diagnostics/session.dart'
    show DiagnosticHealthSnapshot;
import 'package:foresight_core/src/service.dart';
import 'package:test/test.dart';

Future<Map<String, Object?>> _handoffResources(
  List<String> defines,
  String launch,
  List<String> profileDirectories,
) async {
  final result = <String, Object?>{
    'os': Platform.operatingSystem,
    'osVersionNumeric': RegExp(
      r'\d+(?:\.\d+)+',
    ).firstMatch(Platform.operatingSystemVersion)?.group(0),
    'dartVersion': Platform.version.split(' ').first,
    'processors': Platform.numberOfProcessors,
    'launchMode': launch.endsWith('.dill') ? 'portable-kernel' : 'source-jit',
  };
  for (final key in ['NATIVE_ID', 'BUILD_ID', 'DART_SDK_ID']) {
    final prefix = '-DFORESIGHT_DIAGNOSTIC_$key=';
    final value = defines
        .where((value) => value.startsWith(prefix))
        .firstOrNull;
    if (value != null) {
      final id = value.substring(prefix.length);
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) result[key] = id;
    }
  }
  try {
    result['fixtureFdCount'] =
        Directory(Platform.isMacOS ? '/dev/fd' : '/proc/self/fd')
            .listSync(followLinks: false)
            .where((entry) => int.tryParse(entry.path.split('/').last) != null)
            .length;
    final limits = calloc<ffi.Uint64>(2);
    try {
      final getrlimit = ffi.DynamicLibrary.process()
          .lookupFunction<
            ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Uint64>),
            int Function(int, ffi.Pointer<ffi.Uint64>)
          >('getrlimit');
      if (getrlimit(Platform.isMacOS ? 8 : 7, limits) == 0) {
        result['nofileSoft'] = limits[0];
        final hard = limits[1];
        result['nofileHardUnlimited'] = hard < 0 || hard >= 0x7fffffffffffffff;
        if (hard >= 0 && hard < 0x7fffffffffffffff) result['nofileHard'] = hard;
      }
    } finally {
      calloc.free(limits);
    }
  } catch (_) {
    result['fdMetadataAvailable'] = false;
  }
  try {
    final args = Platform.isMacOS
        ? ['-f', '%u %g %Lp', ...profileDirectories]
        : ['-c', '%u %g %a', ...profileDirectories];
    final stat = await runCaptureProcess(
      '/usr/bin/stat',
      args,
      timeout: const Duration(milliseconds: 500),
    );
    final values = (stat.stdout as String).trim().split(RegExp(r'\s+'));
    if (stat.exitCode == 0 &&
        values.length == 9 &&
        values.every((value) => RegExp(r'^[0-9]+$').hasMatch(value))) {
      for (var i = 0; i < 3; i++) {
        result['profile${i}Uid'] = int.parse(values[i * 3]);
        result['profile${i}Gid'] = int.parse(values[i * 3 + 1]);
        result['profile${i}Mode'] = int.tryParse(values[i * 3 + 2], radix: 8);
      }
    } else {
      result['profileMetadataAvailable'] = false;
    }
  } catch (_) {
    result['profileMetadataAvailable'] = false;
  }
  return result;
}

/// A closing owner's refusal as it reaches a client: unavailable, with the
/// reason or, from an older owner, only the unchanged text.
final isClosingRefusal = isA<RpcError>()
    .having((error) => error.code, 'code', RpcErrorCode.unavailable)
    .having(
      (error) => error.message,
      'message',
      'Application service is shutting down; retry after it exits.',
    )
    .having((error) => error.toJson()['reason'], 'reason', 'closing');

void diagnosticWorker(SendPort parent) {
  final commands = ReceivePort();
  // Fatal failures outside the worker's guarded zone still reach onError.
  commands.listen((message) {
    if (message == 'fatal') throw StateError('fatal fixture');
    commands.close();
  });
  runApplicationWorkerZone(() async {
    parent.send(commands.sendPort);
    scheduleMicrotask(() => throw StateError('recoverable fixture'));
    await Future<void>.delayed(Duration.zero);
    parent.send('still healthy');
  });
}

void main() {
  bootstrapSqlSupportFixture();
  test(
    'recoverable worker diagnostics preserve operation and clean exit',
    () async {
      final messages = ReceivePort();
      final errors = ReceivePort();
      final exits = ReceivePort();
      final observedErrors = <dynamic>[];
      errors.listen(observedErrors.add);
      final iterator = StreamIterator<dynamic>(messages);
      try {
        await Isolate.spawn(
          diagnosticWorker,
          messages.sendPort,
          onError: errors.sendPort,
          onExit: exits.sendPort,
        );
        expect(await iterator.moveNext(), isTrue);
        final commands = iterator.current as SendPort;
        expect(await iterator.moveNext(), isTrue);
        expect(iterator.current, 'still healthy');
        final exited = exits.first;
        commands.send('close');
        await exited;
        expect(observedErrors, isEmpty);
      } finally {
        await iterator.cancel();
        messages.close();
        errors.close();
        exits.close();
      }
    },
  );

  test('fatal isolate failures retain their separate error channel', () async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    final iterator = StreamIterator<dynamic>(messages);
    try {
      await Isolate.spawn(
        diagnosticWorker,
        messages.sendPort,
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );
      expect(await iterator.moveNext(), isTrue);
      final commands = iterator.current as SendPort;
      expect(await iterator.moveNext(), isTrue);
      final failed = errors.first;
      final exited = exits.first;
      commands.send('fatal');
      expect((await failed as List).first, contains('fatal fixture'));
      await exited;
    } finally {
      await iterator.cancel();
      messages.close();
      errors.close();
      exits.close();
    }
  });

  test('isolated startup failures still propagate to the host', () async {
    final directory = createTestTempDirectorySync('of-start-fail-');
    final blocked = File('${directory.path}/file')..writeAsStringSync('file');
    await expectLater(
      IsolatedApplicationService.start(
        ProfilePaths(blocked.path, '${directory.path}/run'),
        desktopPeerVerifier: trustInProcessDesktop,
      ),
      throwsA(anything),
    );
  });

  test(
    'startup handoff reaches the real worker and custom profile controls',
    () async {
      // Match the service's canonical profile identity (/tmp is a symlink on
      // macOS) before comparing its endpoint record with the test profile.
      final directory = Directory(
        shortTestTempRoot
            .createTempSync('of-handoff-')
            .resolveSymbolicLinksSync(),
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final profile = ProfilePaths(
        '${directory.path}/data',
        '${directory.path}/run',
      );
      final values = {
        if (runtimeConfiguration['FORESIGHT_SQLITE_LIBRARY']
            case final library?)
          'FORESIGHT_SQLITE_LIBRARY': library,
        'FORESIGHT_DATA': profile.data,
        'FORESIGHT_RUNTIME': profile.runtime,
        'FORESIGHT_SERVICE_TRACE': '1',
        'FORESIGHT_LOG_LEVEL': 'info',
      };
      final handoff = await writeServiceStartupEnvironment(
        Directory(profile.runtime),
        values,
      );
      final environment = {
        for (final entry in Platform.environment.entries)
          if (!entry.key.startsWith('FORESIGHT_')) entry.key: entry.value,
        'HOME': directory.path,
        'XDG_DATA_HOME': '${directory.path}/xdg-data',
        'XDG_RUNTIME_DIR': '${directory.path}/xdg-run',
        'FORESIGHT_STARTUP_ENV': handoff.path,
      };
      final verifiedDefines = await sourceServiceCompileDefines(
        verifiedWorker: true,
      );
      final command = [
        ...verifiedDefines,
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        'bin/service.dart',
      ];
      final process = await Process.start(
        Platform.resolvedExecutable,
        command,
        environment: environment,
        includeParentEnvironment: false,
      );
      final childExitProbe = DiagnosticChildExitProbe.start(process.pid);
      final output = utf8.decoder.bind(process.stdout).join();
      final errors = utf8.decoder.bind(process.stderr).join();
      ServiceClient? client;
      try {
        await eventually(
          () => File('${profile.runtime}/application.sock').existsSync(),
          timeout: const Duration(seconds: 90),
        );
        client = await ServiceClient.connect(serviceEndpoint(profile));
        expect(await client.call('notes.list'), isEmpty);
        expect(File('${profile.data}/application.db').existsSync(), isTrue);
        expect(handoff.existsSync(), isFalse);
        // The real worker must adopt the same profile and qualified logger.
        // Observe the unchanged five-second cold gate through actual status.
        Map<String, Object?> lastHealth = {'observed': false};
        try {
          await eventually(() async {
            final status = await client!.call('status') as Map;
            expect(status['pid'], process.pid);
            expect(status['profile_id'], profile.identity);
            final diagnostics = status['diagnostics'] as Map;
            expect(diagnostics['level'], 'info');
            final snapshot = DiagnosticHealthSnapshot.tryParse(diagnostics);
            lastHealth = snapshot == null
                ? {'observed': true, 'valid': false}
                : {
                    'observed': true,
                    'valid': true,
                    'state': snapshot.state.name,
                    'reason': snapshot.reason.name,
                    'nativeReason': snapshot.nativeReason.name,
                    'known': snapshot.known,
                    'stale': snapshot.stale,
                    'storageConfigured': snapshot.storageConfigured,
                  };
            return diagnostics['state'] == 'healthy';
          }, timeout: const Duration(seconds: 15));
        } catch (_) {
          // Emit only validated closed tags/booleans, never raw status, paths,
          // configuration, child output or exception messages.
          stderr.writeln('Startup handoff health: ${jsonEncode(lastHealth)}');
          stderr.writeln(
            'Startup handoff child exits: ${jsonEncode(childExitProbe.snapshot)}',
          );
          stderr.writeln(
            'Startup handoff resources: ${jsonEncode(await _handoffResources(verifiedDefines, command.last, [directory.path, profile.data, profile.runtime]))}',
          );
          rethrow;
        }
        final statusHandoff = await writeServiceStartupEnvironment(
          Directory(profile.runtime),
          values,
        );
        final status = await Process.run(
          Platform.resolvedExecutable,
          [...command, '--status'],
          environment: {
            ...environment,
            'FORESIGHT_STARTUP_ENV': statusHandoff.path,
          },
          includeParentEnvironment: false,
        ).timeout(const Duration(seconds: 90));
        expect(status.exitCode, 0, reason: '${status.stderr}');
        expect(
          (jsonDecode(status.stdout as String) as Map)['pid'],
          process.pid,
        );
        expect(statusHandoff.existsSync(), isFalse);
      } finally {
        try {
          childExitProbe.close();
        } catch (_) {
          // Observation must never prevent authoritative service cleanup.
        }
        await client?.close();
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(const Duration(seconds: 30));
        await output;
        final diagnostics = await errors;
        expect(process.exitCode, completion(0), reason: diagnostics);
        expect(
          diagnostics,
          isNot(contains('Invalid service environment handoff')),
        );
      }
      final records = Directory('${profile.data}/logs')
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.jsonl'))
          .where((file) {
            final manifest = File('${file.parent.path}/manifest.json');
            return manifest.existsSync() &&
                (jsonDecode(manifest.readAsStringSync()) as Map)['pid'] ==
                    process.pid;
          })
          .expand(
            (file) => const LineSplitter().convert(file.readAsStringSync()),
          )
          .where((line) => line.isNotEmpty)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect(records, isNotEmpty);
      expect(records.every((record) => record['schema'] == 2), isTrue);
      expect(
        records.every(
          (record) => DiagnosticRecord.validWire({
            for (final entry in record.entries)
              if (const {
                'event',
                'component',
                'fields',
                'connection',
                'request',
                'attempt',
                'job',
                'stack',
              }.contains(entry.key))
                entry.key: entry.value,
          }),
        ),
        isTrue,
      );
      expect(
        records.where(
          (record) =>
              record['event'] == 'service.starting' &&
              record['component'] == 'service',
        ),
        hasLength(1),
      );
      expect(
        records.any(
          (record) =>
              record['event'] == 'rpc.completed' &&
              (record['fields'] as Map?)?['operation'] == 'notes.list',
        ),
        isTrue,
      );
    },
    // Both subprocesses compile the service from source under parallel load.
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test('private worker preserves the public Unix socket path limit', () async {
    final saved = Map<String, String>.from(runtimeConfiguration.environment);
    for (final key in [
      'FORESIGHT_HELPER',
      'FORESIGHT_NATIVE',
      'FORESIGHT_INSTALL_ROOT',
      'FORESIGHT_RUNTIME_REVISION',
      'FORESIGHT_MODEL_MANIFEST',
    ]) {
      runtimeConfiguration.environment.remove(key);
    }
    final directory = createTestTempDirectorySync('of-path-');
    IsolatedApplicationService? host;
    ServiceClient? client;
    try {
      final prefix = '${directory.resolveSymbolicLinksSync()}/';
      final padding = 86 - utf8.encode(prefix).length;
      expect(padding, greaterThan(0), reason: 'Use a short test temp root');
      final runtime = '$prefix${List.filled(padding, 'r').join()}';
      final profile = ProfilePaths.resolve({
        'HOME': directory.path,
        'FORESIGHT_DATA': '${directory.path}/data',
        'FORESIGHT_RUNTIME': runtime,
      }, macOS: true);
      expect(utf8.encode('${profile.runtime}/application.sock').length, 103);
      host = await IsolatedApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      expect(FileStat.statSync('$runtime/worker.sock').mode & 0x1ff, 0x180);
      client = await ServiceClient.connect(serviceEndpoint(profile));
      expect((await client.call('status') as Map)['pid'], pid);
      expect(await client.call('notes.list'), isEmpty);
      await host.close();
      expect(
        FileStat.statSync('$runtime/worker.sock').type,
        FileSystemEntityType.notFound,
      );
      expect(
        FileStat.statSync('$runtime/application.sock').type,
        FileSystemEntityType.notFound,
      );
    } finally {
      await client?.close();
      await host?.close();
      directory.deleteSync(recursive: true);
      runtimeConfiguration.environment
        ..clear()
        ..addAll(saved);
    }
  });

  test(
    'concurrent isolated startup protects both sockets before the first RPC',
    () async {
      final saved = Map<String, String>.from(runtimeConfiguration.environment);
      for (final key in [
        'FORESIGHT_HELPER',
        'FORESIGHT_NATIVE',
        'FORESIGHT_INSTALL_ROOT',
        'FORESIGHT_RUNTIME_REVISION',
        'FORESIGHT_MODEL_MANIFEST',
      ]) {
        runtimeConfiguration.environment.remove(key);
      }
      final directory = createTestTempDirectorySync('of-startup-');
      final hosts = <IsolatedApplicationService>[];
      final clients = <ServiceClient>[];
      try {
        await Future.wait(
          List.generate(8, (index) async {
            final profile = ProfilePaths(
              '${directory.path}/$index/data',
              '${directory.path}/$index/run',
            );
            final host = await IsolatedApplicationService.start(
              profile,
              desktopPeerVerifier: trustInProcessDesktop,
            );
            hosts.add(host);
            for (final name in ['application.sock', 'worker.sock']) {
              final mode = FileStat.statSync('${profile.runtime}/$name').mode;
              expect(mode & 0x1ff, 0x180, reason: '$name must be private');
            }
            final client = await ServiceClient.connect(
              serviceEndpoint(profile),
            );
            clients.add(client);
            final status = await client.call('status') as Map;
            expect(status['pid'], pid);
            expect(await client.call('notes.list'), isEmpty);
          }),
        );
      } finally {
        await Future.wait(clients.map((client) => client.close()));
        await Future.wait(hosts.map((host) => host.close()));
        directory.deleteSync(recursive: true);
        runtimeConfiguration.environment
          ..clear()
          ..addAll(saved);
      }
    },
  );
  test(
    'isolated domain preserves multiplexing, committed writes and idle shutdown acknowledgement',
    () async {
      final saved = Map<String, String>.from(runtimeConfiguration.environment);
      for (final key in [
        'FORESIGHT_HELPER',
        'FORESIGHT_NATIVE',
        'FORESIGHT_INSTALL_ROOT',
        'FORESIGHT_RUNTIME_REVISION',
        'FORESIGHT_MODEL_MANIFEST',
      ]) {
        runtimeConfiguration.environment.remove(key);
      }
      runtimeConfiguration.environment['FORESIGHT_SERVICE_TRACE'] = '1';
      final directory = createTestTempDirectorySync('isolated-service-');
      final profile = ProfilePaths(
        '${directory.path}/data',
        '${directory.path}/run',
      );
      final host = await IsolatedApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      ServiceClient? client;
      try {
        for (final name in ['application.sock', 'worker.sock']) {
          expect(
            File('${profile.runtime}/$name').statSync().mode & 0x1ff,
            0x180,
          );
        }
        client = await ServiceClient.connect(serviceEndpoint(profile));
        final status = await client.call('status') as Map;
        expect(status['pid'], pid);
        final events = <Map<String, dynamic>>[];
        final subscription = client.events.stream.listen(events.add);
        final first = await client.call('notes.save', {
          'title': 'Worker-owned note',
          'body': 'Saved on the domain isolate',
        });
        expect(first, isA<Map>());
        final results = await Future.wait([
          client.call('notes.list'),
          client.call('status'),
        ]);
        expect(
          (results.first as List).single['body'],
          'Saved on the domain isolate',
        );
        final stopped = await client.call('service.stop_if_idle', {
          'token': File(
            '${profile.data}/.desktop-capability',
          ).readAsStringSync(),
        });
        expect(stopped, {'stopped': true, 'shutdown_verified': true});
        await host.closed.timeout(const Duration(seconds: 10));
        expect(File('${profile.runtime}/application.sock').existsSync(), false);
        expect(File('${profile.runtime}/worker.sock').existsSync(), false);
        await subscription.cancel();
      } finally {
        await client?.close();
        await host.close();
        directory.deleteSync(recursive: true);
        runtimeConfiguration.environment
          ..clear()
          ..addAll(saved);
      }
    },
  );
  test(
    'explicit shutdown refuses new requests and keeps clients until the worker '
    'closes them (SL-3)',
    () async {
      final saved = Map<String, String>.from(runtimeConfiguration.environment);
      for (final key in [
        'FORESIGHT_HELPER',
        'FORESIGHT_NATIVE',
        'FORESIGHT_INSTALL_ROOT',
        'FORESIGHT_RUNTIME_REVISION',
        'FORESIGHT_MODEL_MANIFEST',
      ]) {
        runtimeConfiguration.environment.remove(key);
      }
      final directory = createTestTempDirectorySync('of-shutdown-');
      // The worker inherits this, so it holds at the gate in this process.
      final gates = await ServiceGates.create(directory);
      runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
          gates.directory.path;
      gates.hold('close.helper_closed');
      final profile = ProfilePaths(
        '${directory.path}/data',
        '${directory.path}/run',
      );
      IsolatedApplicationService? host;
      ServiceClient? client, latecomer;
      try {
        host = await IsolatedApplicationService.start(
          profile,
          desktopPeerVerifier: trustInProcessDesktop,
        );
        client = await ServiceClient.connect(serviceEndpoint(profile));
        expect(await client.call('status'), isA<Map>());
        var workerClosed = false;
        unawaited(host.closed.then((_) => workerClosed = true));
        final shutdown = host.close();
        await gates.reached('close.helper_closed');
        expect(workerClosed, isFalse, reason: 'The gate holds worker cleanup');
        // The attached client's bridge stays: the worker itself refuses.
        expect(
          await client
              .call('status')
              .then<Object?>((_) => null, onError: (Object e) => e),
          isClosingRefusal,
        );
        expect(client.isClosed, isFalse);
        // A new client is refused by the frontend, not dropped.
        latecomer = await ServiceClient.connect(serviceEndpoint(profile));
        expect(
          await latecomer
              .call('status')
              .then<Object?>((_) => null, onError: (Object e) => e),
          isClosingRefusal,
        );
        expect(latecomer.isClosed, isFalse);
        // A refused connection ignores cancels and drops malformed input.
        final raw = await Socket.connect(
          InternetAddress(
            serviceEndpoint(profile),
            type: InternetAddressType.unix,
          ),
          0,
        );
        final received = raw.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        raw.add(
          utf8.encode(
            '{"cancel":3}\n{"id":4,"method":"status","args":{}}\nnot-json\n',
          ),
        );
        final lines = const LineSplitter().convert(utf8.decode(await received));
        raw.destroy();
        expect(lines, hasLength(1));
        expect(jsonDecode(lines.single), {
          'id': 4,
          'error': {
            'code': 'unavailable',
            'message':
                'Application service is shutting down; retry after it exits.',
            'reason': 'closing',
          },
          'done': true,
        });
        final disconnected = [
          client.events.stream.drain<void>(),
          latecomer.events.stream.drain<void>(),
        ];
        gates.releaseAll();
        await shutdown.timeout(const Duration(seconds: 30));
        // Both connections end once the worker and the public socket close.
        await Future.wait(disconnected).timeout(const Duration(seconds: 30));
        expect(client.isClosed, isTrue);
        expect(latecomer.isClosed, isTrue);
      } finally {
        gates.releaseAll();
        await client?.close();
        await latecomer?.close();
        await host?.close();
        directory.deleteSync(recursive: true);
        runtimeConfiguration.environment
          ..clear()
          ..addAll(saved);
      }
    },
    // Above the 60 s gate wait and the 30 s waits, so a hang reports which.
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a refused client that reads slowly gets every closing refusal before its '
    'connection ends with the public socket (SL-3)',
    () async {
      final saved = Map<String, String>.from(runtimeConfiguration.environment);
      for (final key in [
        'FORESIGHT_HELPER',
        'FORESIGHT_NATIVE',
        'FORESIGHT_INSTALL_ROOT',
        'FORESIGHT_RUNTIME_REVISION',
        'FORESIGHT_MODEL_MANIFEST',
      ]) {
        runtimeConfiguration.environment.remove(key);
      }
      final directory = createTestTempDirectorySync('of-slow-refused-');
      final gates = await ServiceGates.create(directory);
      runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
          gates.directory.path;
      // The worker holds before it asks the frontend to remove the public
      // socket, which then ends every refused connection.
      gates.hold('close.before_frontend_release');
      final profile = ProfilePaths(
        '${directory.path}/data',
        '${directory.path}/run',
      );
      IsolatedApplicationService? host;
      ServiceClient? latecomer;
      Socket? raw;
      try {
        host = await IsolatedApplicationService.start(
          profile,
          desktopPeerVerifier: trustInProcessDesktop,
        );
        final endpoint = serviceEndpoint(profile);
        final shutdown = host.close();
        await gates.reached('close.before_frontend_release');
        raw = await Socket.connect(
          InternetAddress(endpoint, type: InternetAddressType.unix),
          0,
        );
        final received = <int>[];
        final ended = Completer<void>();
        final reading = raw.listen(
          received.addAll,
          onError: (Object _) => ended.complete(),
          onDone: ended.complete,
        );
        // This client stops reading, so its refusals queue in the frontend
        // once the socket buffers are full.
        reading.pause();
        const count = 5000;
        raw.add(
          utf8.encode(
            [for (var id = 1; id <= count; id++) '{"id":$id}\n'].join(),
          ),
        );
        await raw.flush();
        // A client that reads normally is refused too, after the frontend
        // has read the requests above.
        latecomer = await ServiceClient.connect(endpoint);
        expect(
          await latecomer
              .call('status')
              .then<Object?>((_) => null, onError: (Object e) => e),
          isClosingRefusal,
        );
        gates.release('close.before_frontend_release');
        // Read only once the public socket is gone, when the frontend ends
        // the refused connections.
        await eventually(
          () =>
              FileSystemEntity.typeSync(endpoint, followLinks: false) ==
              FileSystemEntityType.notFound,
          timeout: const Duration(seconds: 30),
        );
        reading.resume();
        await ended.future.timeout(const Duration(seconds: 30));
        await reading.cancel();
        final lines = const LineSplitter().convert(utf8.decode(received));
        // Every request got its refusal, which a client resends, before EOF;
        // a bare EOF would have left the rest outcomeUnknown.
        expect(lines, hasLength(count));
        for (final line in lines) {
          final frame = jsonDecode(line) as Map;
          expect(RpcError.from(frame['error'] as Object), isClosingRefusal);
        }
        await shutdown.timeout(const Duration(seconds: 30));
      } finally {
        gates.releaseAll();
        raw?.destroy();
        await latecomer?.close();
        await host?.close();
        directory.deleteSync(recursive: true);
        runtimeConfiguration.environment
          ..clear()
          ..addAll(saved);
      }
    },
    // Above the 60 s gate wait and the 30 s waits, so a hang reports which.
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a frontend whose worker died never unlinks a socket that replaced its '
      'own (SL-3)', () async {
    final saved = Map<String, String>.from(runtimeConfiguration.environment);
    for (final key in [
      'FORESIGHT_HELPER',
      'FORESIGHT_NATIVE',
      'FORESIGHT_INSTALL_ROOT',
      'FORESIGHT_RUNTIME_REVISION',
      'FORESIGHT_MODEL_MANIFEST',
    ]) {
      runtimeConfiguration.environment.remove(key);
    }
    final directory = createTestTempDirectorySync('of-replaced-');
    final gates = await ServiceGates.create(directory);
    runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
        gates.directory.path;
    final profile = ProfilePaths(
      '${directory.path}/data',
      '${directory.path}/run',
    );
    IsolatedApplicationService? crashed, replacement;
    ServiceClient? client;
    try {
      crashed = await IsolatedApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      // Hold the frontend once its listener is closed, just before it would
      // unlink the public socket path.
      gates.hold('frontend.listener_closed');
      File(
        '${gates.directory.path}/request.committed.notes.list.crash',
      ).writeAsStringSync('');
      client = await ServiceClient.connect(serviceEndpoint(profile));
      await expectLater(client.call('notes.list'), throwsA(isA<RpcError>()));
      await gates.reached('frontend.listener_closed');
      // A dead worker leaves this process holding the profile lock, so the
      // only replacement that can start now is another owner in this
      // process. It takes over the public socket path. A new owner never
      // deletes a socket that still accepts (SL-7), and the dead worker's
      // listener stays open until this process exits; in another process
      // it would be gone. Remove only its path, which nothing reaches now.
      File('${profile.runtime}/worker.sock').deleteSync();
      runtimeConfiguration.environment.remove('FORESIGHT_SERVICE_GATES');
      replacement = await IsolatedApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      gates.release('frontend.listener_closed');
      await expectLater(crashed.close(), throwsStateError);
      final probe = await ServiceClient.connect(serviceEndpoint(profile));
      try {
        expect((await probe.call('status') as Map)['pid'], pid);
      } finally {
        await probe.close();
      }
    } finally {
      gates.releaseAll();
      await client?.close();
      try {
        await crashed?.close();
      } catch (_) {
        // The crash is reported by close; teardown only needs it finished.
      }
      await replacement?.close();
      directory.deleteSync(recursive: true);
      runtimeConfiguration.environment
        ..clear()
        ..addAll(saved);
    }
    // Above the 60 s gate wait, so a hang reports it.
  }, timeout: const Timeout(Duration(minutes: 2)));
}
