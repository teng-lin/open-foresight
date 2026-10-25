import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  for (final mode in ['prepare', 'spawn', 'ack-exit']) {
    test(
      'native owner $mode retains actual VM ownership and final ACK disposition',
      () async {
        final root = createTestTempDirectorySync('diag-ffi-');
        final library =
            '${root.path}/control.${Platform.isMacOS ? 'dylib' : 'so'}';
        await buildCachedNativeFixture(
          source: 'test/fixtures/diagnostics_owner_ffi.cpp',
          output: library,
        );
        final control = '${root.path}/barrier';
        final release = File('$control.release');
        final process = await Process.start(Platform.resolvedExecutable, [
          'test/fixtures/diagnostics_owner_ffi.dart',
          library,
          control,
          mode,
        ]);
        var exited = false;
        final exit = process.exitCode.then((code) {
          exited = true;
          return code;
        });
        final errors = utf8.decoder.bind(process.stderr).join();
        final observed = <String>[];
        final lines = StreamIterator(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        addTearDown(() async {
          release.writeAsStringSync('release');
          if (!exited) process.kill(ProcessSignal.sigkill);
          await exit.timeout(const Duration(seconds: 5));
          await lines.cancel().timeout(const Duration(seconds: 2));
          final capturedErrors = await errors.timeout(
            const Duration(seconds: 2),
          );
          print(
            'diagnostic owner $mode stdout=$observed stderr=$capturedErrors',
          );
        });
        Future<Map> next() async {
          expect(
            await lines.moveNext().timeout(const Duration(seconds: 8)),
            isTrue,
            reason: await errors.timeout(
              const Duration(milliseconds: 1),
              onTimeout: () => 'child still owned',
            ),
          );
          observed.add(lines.current);
          return jsonDecode(lines.current) as Map;
        }

        final closing = await next();
        expect(closing['phase'], 'close');
        expect(closing['mode'], mode);
        expect(closing['writer_exited'], mode != 'prepare');
        expect(closing['owner_settled'], mode == 'ack-exit');
        expect(closing['requires_explicit_exit'], mode != 'ack-exit');
        expect(closing['flushed'], mode == 'ack-exit');
        expect(
          closing['elapsed_ms'],
          inInclusiveRange(mode == 'ack-exit' ? 0 : 300, 900),
        );
        if (mode != 'ack-exit') {
          expect(exited, isFalse);
          expect(release.existsSync(), isFalse);
          release.writeAsStringSync('release');
        }
        final settled = await next();
        expect(settled, {
          'phase': 'settled',
          'spawn_calls': mode == 'prepare' ? 0 : 1,
        });
        expect(
          await exit.timeout(const Duration(seconds: 5)),
          0,
          reason: await errors,
        );
      },
      timeout: const Timeout(Duration(seconds: 25)),
    );
  }
}
