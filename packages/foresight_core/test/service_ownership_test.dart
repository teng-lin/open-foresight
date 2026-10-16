import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart'
    show serviceEndpoint, ServiceClient;

void main() {
  test(
    'two runtimes and canonical aliases share a profile owner and committed writes',
    () async {
      // Separate OS processes are essential: POSIX advisory locks are per process.
      final scratch = Directory(
        Directory.systemTemp
            .createTempSync('of-owner-')
            .resolveSymbolicLinksSync(),
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
      final diagnostics = StringBuffer();
      Process? owner, contender;
      ServiceClient? first, second;
      Future<Process> launch(String data, String runtime) async {
        final process = await Process.start(
          Platform.resolvedExecutable,
          ['--packages=.dart_tool/package_config.json', 'bin/service.dart'],
          environment: {
            'FORESIGHT_DATA': data,
            'FORESIGHT_RUNTIME': runtime,
            'FORESIGHT_HELPER': '',
          },
        );
        process.stdout.transform(utf8.decoder).listen(diagnostics.write);
        process.stderr.transform(utf8.decoder).listen(diagnostics.write);
        return process;
      }

      try {
        owner = await launch(profile.data, profile.runtime);
        for (var attempt = 0; attempt < 600; attempt++) {
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
        // A stale endpoint and different runtime must recover the same database.
        owner = await launch(other.data, other.runtime);
        for (var attempt = 0; attempt < 600; attempt++) {
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
        for (var attempt = 0; attempt < 600; attempt++) {
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
        scratch.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
