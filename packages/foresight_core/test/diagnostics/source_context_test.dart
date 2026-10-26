import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:foresight_core/src/diagnostics/storage_worker_source.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late DynamicLibrary image;
  setUpAll(() async {
    final root = createTestTempDirectorySync('source-hash-');
    final library = '${root.path}/hash.${Platform.isMacOS ? 'dylib' : 'so'}';
    final compiler = await Process.start('cc', [
      '-std=c11',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-Wpedantic',
      '-shared',
      '-fPIC',
      '../../native/diagnostic_sha256.c',
      '-o',
      library,
    ]);
    final stdout = utf8.decoder.bind(compiler.stdout).join();
    final stderr = utf8.decoder.bind(compiler.stderr).join();
    late final int result;
    try {
      result = await compiler.exitCode.timeout(const Duration(seconds: 45));
    } catch (_) {
      compiler.kill(ProcessSignal.sigkill);
      await compiler.exitCode.timeout(const Duration(seconds: 5));
      print('${await stdout}\n${await stderr}');
      rethrow;
    }
    expect(result, 0, reason: '${await stdout}\n${await stderr}');
    image = DynamicLibrary.open(library);
  });
  test('child streaming hash binding matches standard vectors', () {
    final hash = DiagnosticSourceHash(image);
    expect(
      hash.bytes(utf8.encode('')),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      hash.bytes(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      hash.bytes(utf8.encode('a' * 1000000)),
      'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    );
  });
  test(
    'source verifier refuses unowned package config before manifest read',
    () async {
      final root = createTestTempDirectorySync('source-refuse-');
      final marker = 'a' * 64;
      final manifest = File(
        '${root.path}/build/native/diagnostic-worker-inputs.json',
      );
      manifest.parent.createSync(recursive: true);
      manifest.writeAsBytesSync([
        255,
      ]); // Reading this would throw FormatException.
      await expectLater(
        verifyDiagnosticWorkerSources(
          image: image,
          sourceAnchor: root.path,
          buildRoot: '${root.path}/build',
          sdkRoot: '${root.path}/absent-sdk',
          sdkId: marker,
          packageConfig: '${root.path}/unowned-package-config.json',
          nativeId: marker,
          workerId: marker,
          catalogId: marker,
          mode: 'jit',
        ),
        throwsA(isA<DiagnosticSourceUnavailable>()),
      );
    },
  );
}
