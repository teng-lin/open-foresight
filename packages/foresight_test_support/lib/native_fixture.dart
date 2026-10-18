import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'test_paths.dart';

/// Compile a source/toolchain identity once, then copy it to each test's private
/// output path. Distinct paths keep the stub's native globals isolated.
Future<void> buildCachedNativeFixture({
  required String source,
  required String output,
  String compiler = 'c++',
  Directory? cacheRoot,
}) async {
  final version = await _run(compiler, [
    '--version',
  ], const Duration(seconds: 15));
  if (version.exitCode != 0) {
    throw StateError('Cannot identify fixture compiler: ${version.stderr}');
  }
  final bytes = await File(source).readAsBytes();
  final identity = sha256.convert([
    ...utf8.encode(
      jsonEncode([
        Platform.operatingSystem,
        Platform.version,
        compiler,
        version.stdout.toString(),
        '-std=c++17',
        '-shared',
        '-fPIC',
      ]),
    ),
    ...bytes,
  ]).toString();
  final root =
      cacheRoot ??
      Directory('${shortTestTempRoot.path}/foresight-native-fixtures');
  await root.create(recursive: true);
  final artifact = File(
    '${root.path}/$identity.${Platform.isMacOS ? 'dylib' : 'so'}',
  );
  final lock = Directory('${artifact.path}.lock');
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  var locked = false;
  while (!locked) {
    // Directory.create treats an existing directory as success. System mkdir
    // supplies the exclusive create needed for a lock across test processes.
    final created = await _run('/bin/mkdir', [
      lock.path,
    ], const Duration(seconds: 5));
    locked = created.exitCode == 0;
    if (!locked) {
      if (!lock.existsSync()) {
        throw FileSystemException(
          'Cannot create fixture lock: ${created.stderr}',
          lock.path,
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Timed out waiting for fixture build: ${lock.path}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  try {
    if (!await artifact.exists()) {
      final staging = await root.createTemp('.fixture-build-');
      try {
        final input = File('${staging.path}/fixture.cpp');
        await input.writeAsBytes(bytes);
        final built = '${staging.path}/fixture';
        final build = await _run(compiler, [
          '-std=c++17',
          '-shared',
          '-fPIC',
          input.path,
          '-o',
          built,
        ], const Duration(minutes: 1));
        if (build.exitCode != 0) {
          throw StateError(
            'Native fixture compilation failed: ${build.stdout}\n${build.stderr}',
          );
        }
        await File(built).rename(artifact.path);
      } finally {
        await staging.delete(recursive: true);
      }
    }
    await artifact.copy(output);
  } finally {
    await lock.delete();
  }
}

Future<ProcessResult> _run(
  String executable,
  List<String> args,
  Duration timeout,
) async {
  final process = await Process.start(executable, args);
  final stdout = utf8.decoder.bind(process.stdout).join();
  final stderr = utf8.decoder.bind(process.stderr).join();
  try {
    final code = await process.exitCode.timeout(timeout);
    return ProcessResult(process.pid, code, await stdout, await stderr);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await stdout;
    await stderr;
    throw StateError('Native fixture command timed out: $executable');
  }
}
