import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart'
    show serviceEndpoint, ServiceClient;

/// The installer uses flock on the new hashed installation path. Keep its
/// actual kernel lease in a separate process; POSIX FileLock is a different
/// namespace on Linux and cannot supply this refusal/ordering oracle.
final class _InstallerFlock {
  _InstallerFlock(this.process, this.output, this.errorsDone, this.errors) {
    exited = process.exitCode.then((code) {
      _ended = true;
      return code;
    });
  }
  final Process process;
  final StreamIterator<String> output;
  final Future<void> errorsDone;
  final StringBuffer errors;
  bool _closed = false, _ended = false;
  late final Future<int> exited;

  static Future<_InstallerFlock> start(String path) async {
    final process = await Process.start(
      Platform.environment['FORESIGHT_PYTHON'] ?? 'python3',
      [
        '-u',
        '-c',
        """
import fcntl,os,sys
with os.fdopen(os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600),'a') as lease:
    print('ready',flush=True)
    for command in sys.stdin:
        command=command.strip()
        if command not in ('exclusive','release'):
            raise RuntimeError('Unexpected fixture command')
        operation=fcntl.LOCK_UN if command=='release' else fcntl.LOCK_EX|fcntl.LOCK_NB
        try:
            fcntl.flock(lease,operation)
            print('ok',flush=True)
        except BlockingIOError:
            print('busy',flush=True)
""",
        path,
      ],
    );
    final output = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final errors = StringBuffer();
    final done = process.stderr.transform(utf8.decoder).forEach(errors.write);
    final fixture = _InstallerFlock(process, output, done, errors);
    try {
      expect(
        await output.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(output.current, 'ready', reason: errors.toString());
      return fixture;
    } catch (_) {
      await fixture.close();
      rethrow;
    }
  }

  Future<bool> tryExclusive() async => await _command('exclusive') == 'ok';
  Future<void> release() async => expect(await _command('release'), 'ok');
  Future<String> _command(String command) async {
    process.stdin.writeln(command);
    await process.stdin.flush().timeout(const Duration(seconds: 5));
    expect(
      await output.moveNext().timeout(const Duration(seconds: 5)),
      isTrue,
      reason: errors.toString(),
    );
    final reply = output.current;
    expect(reply, anyOf('ok', 'busy'), reason: errors.toString());
    return reply;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await process.stdin.close().timeout(const Duration(seconds: 5));
      expect(
        await exited.timeout(const Duration(seconds: 5)),
        0,
        reason: errors.toString(),
      );
    } finally {
      if (!_ended) {
        process.kill(ProcessSignal.sigkill);
        await exited.timeout(const Duration(seconds: 5));
      }
      await output.cancel().timeout(const Duration(seconds: 5));
      await errorsDone.timeout(const Duration(seconds: 5));
    }
  }
}

void main() {
  test(
    'two runtimes and canonical aliases share a profile owner and committed writes',
    () async {
      // Separate OS processes are essential: POSIX advisory locks are per process.
      final scratch = Directory(
        createTestTempDirectorySync('of-owner-').resolveSymbolicLinksSync(),
      );
      final profile = ProfilePaths.resolve({
        'HOME': scratch.path,
        'FORESIGHT_DATA': '${scratch.path}/data',
        'FORESIGHT_RUNTIME': '${scratch.path}/a',
      });
      final kernel = File('${scratch.path}/service.dill');
      final compilation = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        'bin/service.dart',
        '-o',
        kernel.path,
      ]);
      expect(
        compilation.exitCode,
        0,
        reason: '${compilation.stdout} ${compilation.stderr}',
      );
      final installation = Directory('${scratch.path}/Open Foresight.app')
        ..createSync();
      final installationPath = installationLockPath(installation.path);
      privateDirectory(File(installationPath).parent.path);
      final installerLock = await _InstallerFlock.start(installationPath);
      final diagnostics = StringBuffer();
      Process? owner, contender;
      ServiceClient? first, second;
      Future<Process> launch(
        String data,
        String runtime, {
        bool invalidNative = false,
      }) async {
        final process = await Process.start(
          Platform.resolvedExecutable,
          [kernel.path],
          environment: {
            'FORESIGHT_DATA': data,
            'FORESIGHT_RUNTIME': runtime,
            'FORESIGHT_HELPER': '',
            'FORESIGHT_INSTALL_ROOT': installation.path,
            'FORESIGHT_RUNTIME_REVISION': 'integration-revision',
            if (invalidNative) 'FORESIGHT_NATIVE': '/missing-native-library',
          },
        );
        process.stdout.transform(utf8.decoder).listen(diagnostics.write);
        process.stderr.transform(utf8.decoder).listen(diagnostics.write);
        return process;
      }

      try {
        expect(await installerLock.tryExclusive(), isTrue);
        contender = await launch(
          profile.data,
          profile.runtime,
          invalidNative: true,
        );
        expect(
          await contender.exitCode.timeout(const Duration(seconds: 60)),
          isNot(0),
        );
        expect(diagnostics.toString(), contains('update is in progress'));
        expect(File('${profile.data}/application.db').existsSync(), false);
        await installerLock.release();
        owner = await launch(profile.data, profile.runtime);
        for (
          final pollingClock = Stopwatch()..start();
          pollingClock.elapsed < const Duration(seconds: 60);
        ) {
          try {
            first = await ServiceClient.connect(serviceEndpoint(profile));
            break;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(first, isNotNull, reason: diagnostics.toString());
        final status = await first!.call('status') as Map;
        expect(status['pid'], owner.pid);
        expect(status['application_api_version'], 1);
        expect(
          status['installation_root'],
          canonicalProfilePath(installation.path),
        );
        expect(status['runtime_revision'], 'integration-revision');
        final matching = RuntimeConfiguration({
          'FORESIGHT_INSTALL_ROOT': installation.path,
          'FORESIGHT_RUNTIME_REVISION': 'integration-revision',
        });
        validateServiceCompatibility(status, configuration: matching);
        expect(
          () => validateServiceCompatibility(
            status,
            configuration: RuntimeConfiguration({
              'FORESIGHT_INSTALL_ROOT': installation.path,
              'FORESIGHT_RUNTIME_REVISION': 'different',
            }),
          ),
          throwsStateError,
        );
        final copy = Directory('${scratch.path}/Other.app')..createSync();
        expect(
          () => validateServiceCompatibility(
            status,
            configuration: RuntimeConfiguration({
              'FORESIGHT_INSTALL_ROOT': copy.path,
              'FORESIGHT_RUNTIME_REVISION': 'integration-revision',
            }),
          ),
          throwsStateError,
        );
        final installAlias = Link('${scratch.path}/App Alias')
          ..createSync(installation.path);
        validateServiceCompatibility(
          status,
          configuration: RuntimeConfiguration({
            'FORESIGHT_INSTALL_ROOT': installAlias.path,
            'FORESIGHT_RUNTIME_REVISION': 'integration-revision',
          }),
        );
        expect(
          () => validateServiceCompatibility({}, configuration: matching),
          throwsStateError,
        );
        validateServiceCompatibility(
          {},
          configuration: RuntimeConfiguration({}),
        );
        expect(await installerLock.tryExclusive(), isFalse);
        final alias = Link('${scratch.path}/alias')..createSync(profile.data);
        final other = ProfilePaths.resolve({
          'HOME': scratch.path,
          'FORESIGHT_DATA': alias.path,
          'FORESIGHT_RUNTIME': '${scratch.path}/b',
        });
        expect(other.data, profile.data);
        second = await ServiceClient.connect(serviceEndpoint(other));
        expect((await second.call('status') as Map)['pid'], owner.pid);
        await first.call('notes.save', {
          'title': 'Shared',
          'body': 'Committed',
        });
        expect(
          (await second.call('notes.list') as List).single['body'],
          'Committed',
        );
        contender = await launch(other.data, other.runtime);
        expect(
          await contender.exitCode.timeout(const Duration(seconds: 60)),
          isNot(0),
        );
        expect((await second.call('status') as Map)['pid'], owner.pid);
        await first.close();
        first = null;
        await second.close();
        second = null;
        owner.kill(ProcessSignal.sigterm);
        expect(
          await owner.exitCode.timeout(const Duration(seconds: 60)),
          0,
          reason: diagnostics.toString(),
        );
        owner = null;
        expect(await installerLock.tryExclusive(), isTrue);
        await installerLock.release();
        // A stale endpoint and different runtime must recover the same database.
        owner = await launch(other.data, other.runtime);
        for (
          final pollingClock = Stopwatch()..start();
          pollingClock.elapsed < const Duration(seconds: 60);
        ) {
          try {
            first = await ServiceClient.connect(serviceEndpoint(other));
            break;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(first, isNotNull, reason: diagnostics.toString());
        expect(
          (await first!.call('notes.list') as List).single['body'],
          'Committed',
        );
        expect(serviceEndpoint(other), '${other.runtime}/application.sock');
        await first.close();
        first = null;
        owner.kill(ProcessSignal.sigkill);
        await owner.exitCode;
        final crashRuntime = '${scratch.path}/c';
        owner = await launch(other.data, crashRuntime);
        final crashProfile = ProfilePaths(other.data, crashRuntime);
        for (
          final pollingClock = Stopwatch()..start();
          pollingClock.elapsed < const Duration(seconds: 60);
        ) {
          try {
            first = await ServiceClient.connect(serviceEndpoint(crashProfile));
            final state = await first.call('status') as Map;
            if (state['pid'] == owner.pid) break;
            await first.close();
            first = null;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(first, isNotNull, reason: diagnostics.toString());
        expect(
          serviceEndpoint(crashProfile),
          '${other.runtime}/application.sock',
        );
        await first!.close();
        first = null;
        await eventually(
          () => diagnostics.toString().contains('Helper startup:'),
        );
        final administration = await Process.run(
          Platform.resolvedExecutable,
          [kernel.path, '--stop-if-idle=${owner.pid}'],
          environment: {
            'FORESIGHT_DATA': other.data,
            'FORESIGHT_RUNTIME': other.runtime,
          },
        );
        expect(
          administration.exitCode,
          0,
          reason: administration.stderr.toString(),
        );
        expect(jsonDecode(administration.stdout.toString()), {
          'stopped': true,
          'shutdown_verified': true,
        });
        expect(await owner.exitCode.timeout(const Duration(seconds: 10)), 0);
        owner = null;
        // EOF from a fake peer cannot be mistaken for successful shutdown.
        final fake = await ServerSocket.bind(
          InternetAddress(
            '${other.runtime}/application.sock',
            type: InternetAddressType.unix,
          ),
          0,
        );
        final peer = fake.listen((socket) {
          socket.listen((_) => socket.destroy());
        });
        try {
          final missingAck = await Process.run(
            Platform.resolvedExecutable,
            [kernel.path, '--stop-if-idle'],
            environment: {
              'FORESIGHT_DATA': other.data,
              'FORESIGHT_RUNTIME': other.runtime,
            },
          );
          expect(missingAck.exitCode, isNot(0));
          expect(missingAck.stdout, isEmpty);
        } finally {
          await peer.cancel();
          await fake.close();
        }
      } finally {
        await first?.close();
        await second?.close();
        for (final process in [owner, contender]) {
          if (process == null) continue;
          process.kill(ProcessSignal.sigterm);
          try {
            await process.exitCode.timeout(const Duration(seconds: 10));
          } on TimeoutException {
            process.kill(ProcessSignal.sigkill);
            await process.exitCode;
          }
        }
        await installerLock.close();
        File(installationPath).parent.deleteSync(recursive: true);
        scratch.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
