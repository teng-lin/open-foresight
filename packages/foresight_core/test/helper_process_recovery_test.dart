import 'dart:io';

import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_core/src/generated/helper_control.pbgrpc.dart'
    as control;
import 'package:grpc/grpc.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  final native = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  final executable = Platform.environment['FORESIGHT_HELPER'];
  late String fixtureExecutable;
  setUpAll(() async {
    final build = createTestTempDirectorySync('helper-fixture-build-');
    fixtureExecutable = '${build.path}/recovery-helper';
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/fixtures/recovery_helper.dart',
      '-o',
      fixtureExecutable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
  });
  late Directory root;
  late Helper helper;
  late Map<String, String> environment;
  setUp(() async {
    environment = Map.of(runtimeConfiguration.environment);
    root = createTestTempDirectorySync('hp-');
    runtimeConfiguration.environment['FORESIGHT_HELPER'] = fixtureExecutable;
    helper = Helper('${root.path}/helper.sock', '${root.path}/storage');
  });
  setUp(() {
    addTearDown(() async {
      await helper.close();
      root.deleteSync(recursive: true);
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
    });
  });

  test(
    'concurrent starts share one child and crash recovery restores RPC',
    () async {
      var ready = 0;
      helper.onReady = () async => ready++;
      final first = helper.start();
      expect(helper.start(), same(first));
      await first;
      final child = helper.process!;
      expect((await helper.client.ping(PingRequest())).success, isTrue);
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
      await eventually(
        () => ready == 2 && helper.snapshot != null,
        timeout: const Duration(seconds: 25),
      );
      expect(helper.process!.pid, isNot(child.pid));
      expect(helper.restarts, 1);
      expect((await helper.client.ping(PingRequest())).success, isTrue);
      final launches = File('${root.path}/storage/launches').readAsLinesSync();
      expect(launches, ['${child.pid}', '${helper.process!.pid}']);
      await helper.recover();
      expect(File('${root.path}/storage/launches').readAsLinesSync(), launches);
      expect(helper.restarts, 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'shutdown escalates a child ignoring SIGTERM and never restarts it',
    () async {
      final storage = Directory('${root.path}/storage')..createSync();
      File('${storage.path}/ignore-term').writeAsStringSync('');
      await helper.start();
      expect(helper.state, startsWith('live'), reason: helper.state);
      final child = helper.process!;
      final closing = helper.close();
      expect(helper.close(), same(closing));
      await eventually(
        () => File('${storage.path}/term-received').existsSync(),
      );
      await closing.timeout(const Duration(seconds: 8));
      expect(await child.exitCode, -ProcessSignal.sigkill.signalNumber);
      expect(helper.stopping, isTrue);
      expect(helper.restarts, 0);
      expect(File('${storage.path}/launches').readAsLinesSync(), [
        '${child.pid}',
      ]);
      await expectLater(helper.recover(), throwsStateError);
    },
  );

  test(
    'failed automatic relaunch stays degraded and explicit recovery retries',
    () async {
      await helper.start();
      expect(helper.state, startsWith('live'), reason: helper.state);
      final child = helper.process!;
      runtimeConfiguration.environment['FORESIGHT_HELPER'] = '/missing-helper';
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
      await eventually(
        () => helper.state.startsWith('app restore failed:'),
        timeout: const Duration(seconds: 25),
      );
      expect(helper.snapshot, isNull);
      expect(helper.process, isNull);
      runtimeConfiguration.environment['FORESIGHT_HELPER'] = fixtureExecutable;
      final recovering = helper.recover();
      expect(helper.recover(), same(recovering));
      await recovering;
      await eventually(() => helper.snapshot?.pipeline == 'ready');
      expect((await helper.client.ping(PingRequest())).success, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  for (final exited in [false, true]) {
    test(
      'adopted native helper ownership is verified (already exited=$exited)',
      () async {
        await helper.close();
        runtimeConfiguration.environment['FORESIGHT_HELPER'] = executable!;
        runtimeConfiguration.environment['FORESIGHT_NATIVE'] = native!;
        runtimeConfiguration.environment.remove('FORESIGHT_RUNTIME_REVISION');
        expect(
          (await Process.run('/bin/chmod', ['700', root.path])).exitCode,
          0,
        );
        helper = Helper(
          '${root.path}/native.sock',
          '${root.path}/native-storage',
        );
        final child = await Process.start(executable, [
          helper.socket,
          helper.storage,
        ]);
        final output = child.stdout
            .transform(const SystemEncoding().decoder)
            .join();
        final errors = child.stderr
            .transform(const SystemEncoding().decoder)
            .join();
        addTearDown(() async {
          child.kill(ProcessSignal.sigkill);
          await child.exitCode;
          // Preserve child diagnostics on failure in the test runner's output.
          final diagnostics = '${await output}${await errors}';
          if (diagnostics.isNotEmpty) print(diagnostics);
        });
        await eventually(() async {
          try {
            await helper.client.ping(
              PingRequest(),
              options: CallOptions(timeout: const Duration(milliseconds: 200)),
            );
            return true;
          } catch (_) {
            return false;
          }
        }, timeout: const Duration(seconds: 10));
        await helper.start();
        expect(helper.process, isNull);
        final state = await control.HelperControlClient(
          helper.channel,
        ).getState(control.Empty());
        expect(state.instanceId, startsWith('${child.pid}-'));
        // WatchState delivery is asynchronous; close must inspect this exact owner.
        helper.snapshot = state;
        if (exited) {
          child.kill();
          await child.exitCode;
        }
        await helper.close();
        expect(helper.shutdownVerified, isTrue);
        expect(
          await child.exitCode.timeout(const Duration(seconds: 3)),
          -ProcessSignal.sigterm.signalNumber,
        );
      },
      skip: native == null || executable == null
          ? 'Requires the built native library and helper supplied by the core CI gate'
          : false,
    );
  }
}
