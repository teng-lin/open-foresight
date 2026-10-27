import '../sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/persistence_bootstrap.dart';
import 'package:foresight_test_support/desktop_identity.dart';
import 'package:foresight_test_support/hooked_service.dart' show ServiceGates;

Future<void> until(bool Function() ready, String phase) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed > const Duration(seconds: 12)) {
      throw StateError('Native frontend control timed out: $phase');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<bool> processMatches(int child, String path) async {
  final probe = await Process.start('/bin/ps', [
    '-ww',
    '-p',
    '$child',
    '-o',
    'command=',
  ]);
  final text = utf8.decoder.bind(probe.stdout).join();
  final errors = probe.stderr.drain<void>();
  try {
    final code = await probe.exitCode.timeout(const Duration(seconds: 2));
    return code == 0 && (await text).contains(path);
  } on TimeoutException {
    probe.kill(ProcessSignal.sigkill);
    await probe.exitCode;
    return false;
  } finally {
    await text;
    await errors;
  }
}

Future<bool> replacementIsolateRefuses(
  String data,
  String runtime,
  String library,
  SqliteRuntimeBootstrap sqlRuntime,
) => Isolate.run(() async {
  bindSqliteRuntime(sqlRuntime);
  // The environment configuration list is deliberately empty. A selected
  // native-capable mapping must still refuse after quarantine.
  runtimeConfiguration.environment
    ..clear()
    ..['FORESIGHT_NATIVE'] = library;
  try {
    final host = await IsolatedApplicationService.start(
      ProfilePaths(data, runtime),
    );
    await host.close();
    return false;
  } catch (error) {
    return error.toString().contains('restart the service');
  }
});

Future<ServiceClient> desktop(ProfilePaths profile) async {
  final client = await ServiceClient.connect(serviceEndpoint(profile));
  await client.call('security.attach_desktop', {
    'token': File('${profile.data}/.desktop-capability').readAsStringSync(),
    'visible': true,
  });
  return client;
}

Future<void> ready(ServiceClient client) async {
  final clock = Stopwatch()..start();
  // Startup may publish status before its lazy runtime appears.
  while (clock.elapsed < const Duration(seconds: 12)) {
    if (((await client.call('status') as Map)['generation']
            as Map?)?['state'] ==
        'ready') {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Native frontend model never became ready');
}

Future<void> main(List<String> args) async {
  final sqlRuntime = bootstrapSqlSupportFixture();
  final root = Directory(args[0]), mode = args[1], library = args[2];
  final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
  final runner = '${root.path}/model-worker';
  Directory(profile.data).createSync(recursive: true);
  final permission = await Process.run('/bin/chmod', ['700', profile.data]);
  if (permission.exitCode != 0) {
    throw StateError('Private frontend control data');
  }
  final gates = await ServiceGates.create(root);
  runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
      gates.directory.path;
  if (mode == 'ack_loss') {
    File(
      '${gates.directory.path}/worker.native_admission_granted.crash',
    ).writeAsStringSync('');
  }
  final store = Store('${profile.data}/application.db');
  if (mode != 'sql_loss') {
    await store.register(
      'generation',
      '${root.path}/model',
      runner,
      backend: 'litert_lm',
    );
  }
  final meeting = store.meeting('Native ownership control');
  store.transcript(
    meeting,
    'Mira owns the release draft.',
    true,
    0,
    1000,
    'microphone',
  );
  store.close();
  IsolatedApplicationService? first, second;
  ServiceClient? a, b;
  var passed = false;
  try {
    Object? loss;
    try {
      first = await IsolatedApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      if (mode == 'ack_loss') {
        await first.closed.timeout(const Duration(seconds: 12));
        try {
          await first.close();
        } catch (error) {
          loss = error;
        }
      } else {
        a = await desktop(profile);
        if (mode != 'sql_loss') await ready(a);
        if (mode == 'work_loss') {
          a.call('meetings.generate', {
            'id': meeting,
            'kind': 'summary',
          }).ignore();
          await until(
            () => File('$runner.entered').existsSync(),
            'native work entered',
          );
        }
        if (mode == 'clean') {
          File('$runner.release').writeAsStringSync('release');
          await a.call('meetings.generate', {'id': meeting, 'kind': 'summary'});
          await a.close();
          a = null;
          await first.close();
        } else {
          File(
            '${gates.directory.path}/request.committed.notes.list.crash',
          ).writeAsStringSync('');
          try {
            await a.call('notes.list');
          } catch (_) {}
          try {
            await first.close();
          } catch (error) {
            loss = error;
          }
        }
      }
    } catch (error) {
      if (mode != 'ack_loss') rethrow;
      loss = error;
    }
    final nativeLoss = mode == 'work_loss' || mode == 'ack_loss';
    if (nativeLoss &&
        !(loss?.toString().contains('restart the service') ?? false)) {
      throw StateError(
        'Native worker loss was not surfaced as restart-required: $loss',
      );
    }
    if (mode == 'ack_loss' && File('$runner.probed').existsSync()) {
      throw StateError(
        'ACK-gap control unexpectedly created native model work',
      );
    }
    final priorWorkers = File('$runner.starts').existsSync()
        ? File('$runner.starts').readAsLinesSync().map(int.parse).toList()
        : <int>[];
    if (mode == 'work_loss' &&
        (priorWorkers.length != 1 ||
            !await processMatches(priorWorkers.single, runner))) {
      throw StateError(
        'Control did not retain actual native work after isolate loss',
      );
    }
    if (mode == 'clean') {
      for (final child in priorWorkers) {
        final alive = await processMatches(child, runner);
        final graceful = File('$runner.closed.$child').existsSync();
        if (alive || !graceful) {
          throw StateError(
            'Clean replacement preceded actual native worker exit: '
            'alive=$alive graceful=$graceful root=${root.path} '
            'trace=${File('$runner.trace').readAsStringSync()}',
          );
        }
      }
    }
    final stale = File('${profile.runtime}/worker.sock');
    if (stale.existsSync()) stale.deleteSync();
    runtimeConfiguration.environment.remove('FORESIGHT_SERVICE_GATES');
    if (nativeLoss) {
      var refused = false;
      try {
        second = await IsolatedApplicationService.start(profile);
      } catch (error) {
        refused = error.toString().contains('restart the service');
      }
      if (!refused ||
          !await replacementIsolateRefuses(
            profile.data,
            profile.runtime,
            library,
            sqlRuntime,
          )) {
        throw StateError(
          'Native loss permitted a frontend or isolate replacement',
        );
      }
      final now = File('$runner.starts').existsSync()
          ? File('$runner.starts').readAsLinesSync()
          : <String>[];
      if (now.length != priorWorkers.length) {
        throw StateError('Replacement started overlapping native work');
      }
    } else {
      second = await IsolatedApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      b = await desktop(profile);
      if (mode == 'clean') await ready(b);
      await b.call('notes.list');
      await b.close();
      b = null;
      await second.close();
      second = null;
    }
    passed = true;
    print(
      jsonEncode({
        'mode': mode,
        'restart_required': nativeLoss,
        'replacement_allowed': !nativeLoss,
        'native_workers_before_replacement': priorWorkers.length,
      }),
    );
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
  } finally {
    gates.releaseAll();
    File('$runner.release').writeAsStringSync('release');
    await a?.close();
    await b?.close();
    try {
      await second?.close().timeout(const Duration(seconds: 5));
    } catch (_) {}
    try {
      await first?.close().timeout(const Duration(seconds: 5));
    } catch (_) {}
    // This disposable VM owns any deliberately orphaned control. Its native
    // supervisors reap those workers on process exit; the parent verifies it.
    exit(passed ? 0 : 1);
  }
}
