import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/service_startup.dart'
    show serviceLaunchLeaseWithdrawn;
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ProfilePaths profile;
  late Map<String, String> saved;
  setUp(() {
    final temporary = createTestTempDirectorySync('startup-boundary-');
    root = Directory(temporary.resolveSymbolicLinksSync());
    profile = ProfilePaths('${root.path}/data', '${root.path}/run');
    privateDirectory(profile.data);
    privateDirectory(profile.runtime);
    saved = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment.remove('FORESIGHT_STARTUP_STATUS');
  });
  tearDown(() {
    runtimeConfiguration.environment
      ..clear()
      ..addAll(saved);
  });

  test('only the withdrawn private launch lease cancels a launch', () {
    expect(serviceLaunchLeaseWithdrawn(profile), isFalse);
    final foreign = File('${root.path}/startup-foreign.json')
      ..writeAsStringSync('foreign owner');
    runtimeConfiguration.environment['FORESIGHT_STARTUP_STATUS'] = foreign.path;
    foreign.deleteSync();
    expect(serviceLaunchLeaseWithdrawn(profile), isFalse);
    final lease = File('${profile.runtime}/startup-current.json')
      ..writeAsStringSync('{}');
    runtimeConfiguration.environment['FORESIGHT_STARTUP_STATUS'] = lease.path;
    expect(serviceLaunchLeaseWithdrawn(profile), isFalse);
    lease.deleteSync();
    expect(serviceLaunchLeaseWithdrawn(profile), isTrue);
    recordServiceStartupFailure(profile, StateError('late failure'));
    expect(lease.existsSync(), isFalse);
  });

  test('ownership contention is recorded without a false startup failure', () {
    final lease = File('${profile.runtime}/startup-contended.json')
      ..writeAsStringSync('{}');
    runtimeConfiguration.environment['FORESIGHT_STARTUP_STATUS'] = lease.path;
    recordServiceStartupFailure(profile, ServiceOwnershipContended('held'));
    expect(jsonDecode(lease.readAsStringSync()), {'state': 'contended'});
    expect(lease.statSync().mode & 0x1ff, 0x180);
    recordServiceStartupFailure(profile, StateError('configuration rejected'));
    expect(jsonDecode(lease.readAsStringSync()), {
      'state': 'failed',
      'error': 'configuration rejected',
    });
    expect(Directory(profile.runtime).listSync().map((entry) => entry.path), [
      lease.path,
    ]);
  });

  test('failure reporting cannot overwrite a foreign file or symlink', () {
    final foreign = File('${root.path}/startup-foreign.json')
      ..writeAsStringSync('preserve foreign lease');
    runtimeConfiguration.environment['FORESIGHT_STARTUP_STATUS'] = foreign.path;
    recordServiceStartupFailure(profile, StateError('ignored'));
    expect(foreign.readAsStringSync(), 'preserve foreign lease');
    final link = Link('${profile.runtime}/startup-link.json')
      ..createSync(foreign.path);
    runtimeConfiguration.environment['FORESIGHT_STARTUP_STATUS'] = link.path;
    recordServiceStartupFailure(profile, StateError('also ignored'));
    expect(link.targetSync(), foreign.path);
    expect(foreign.readAsStringSync(), 'preserve foreign lease');
  });

  test(
    'failed status staging preserves the lease and reports no false outcome',
    () {
      final lease = File('${profile.runtime}/startup-blocked.json')
        ..writeAsStringSync('{"state":"launching"}');
      final occupied = Directory('${lease.path}.$pid')..createSync();
      final marker = File('${occupied.path}/owner')
        ..writeAsStringSync('retain');
      runtimeConfiguration.environment['FORESIGHT_STARTUP_STATUS'] = lease.path;
      recordServiceStartupFailure(
        profile,
        StateError('cannot publish failure'),
      );
      expect(jsonDecode(lease.readAsStringSync()), {'state': 'launching'});
      expect(marker.readAsStringSync(), 'retain');
    },
  );

  test(
    'an unsafe ownership lock blocks launch without modifying its owner',
    () async {
      final lock = Directory('${profile.data}/.application.lock')..createSync();
      final marker = File('${lock.path}/owner')..writeAsStringSync('retain');
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] = '/bin/false';
      await expectLater(
        ensureService(profile),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'unsafe ownership',
            contains('ownership lock is missing or unsafe'),
          ),
        ),
      );
      expect(marker.readAsStringSync(), 'retain');
      expect(Directory(profile.runtime).listSync(), isEmpty);
    },
  );

  test(
    'invalid probe budgets fail before launching or creating endpoints',
    () async {
      final missing = ProfilePaths(
        '${root.path}/absent',
        '${root.path}/unused',
      );
      await expectLater(
        ensureService(missing, statusProbeLimit: Duration.zero),
        throwsArgumentError,
      );
      await expectLater(
        ensureServiceSnapshot(
          missing,
          statusProbeLimit: const Duration(microseconds: -1),
        ),
        throwsArgumentError,
      );
      expect(Directory(missing.data).existsSync(), isFalse);
      expect(Directory(missing.runtime).existsSync(), isFalse);
    },
  );

  test(
    'release requires the real owner lock, then preserves unclean recovery evidence',
    () async {
      final lock = '${profile.data}/.application.lock';
      final process = await Process.start(
        Platform.environment['FORESIGHT_PYTHON'] ?? 'python3',
        [
          '-u',
          '-c',
          'import fcntl,sys\n'
              'f=open(sys.argv[1],"a")\n'
              'fcntl.lockf(f,fcntl.LOCK_EX)\n'
              'print("locked",flush=True)\n'
              'sys.stdin.readline()\n'
              'f.close()\n',
          lock,
        ],
      ).timeout(const Duration(seconds: 10));
      final errors = process.stderr.transform(utf8.decoder).join();
      final output = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      var released = false;
      Future<void> release() async {
        if (released) return;
        released = true;
        process.stdin.writeln('release');
        await process.stdin.flush();
        await process.stdin.close();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 10)),
          0,
          reason: await errors,
        );
        await output.cancel();
      }

      addTearDown(release);
      expect(
        await output.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      expect(output.current, 'locked');
      final record = File('${profile.data}/.application-endpoint.json')
        ..writeAsStringSync('retained recovery record');
      expect(profileReleased(profile), isFalse);
      expect(profileLeftUnclean(profile), isFalse);
      expect(
        await awaitProfileRelease(profile, process.pid, timeout: Duration.zero),
        isFalse,
      );
      await expectLater(
        requireProfileRelease(profile, process.pid, timeout: Duration.zero),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'diagnostic',
            allOf(contains('${process.pid}'), contains('within 0 s')),
          ),
        ),
      );
      await release();
      await requireProfileRelease(profile, null, timeout: Duration.zero);
      expect(profileLeftUnclean(profile), isTrue);
      expect(record.readAsStringSync(), 'retained recovery record');
    },
  );
}
