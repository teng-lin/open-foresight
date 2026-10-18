import 'dart:io';

import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test(
    'concurrent suites compile once and copy independent fixture files',
    () async {
      final directory = createTestTempDirectorySync('native-fixture-cache-');
      final source = File('${directory.path}/source.cpp')
        ..writeAsStringSync('first source');
      final counter = File('${directory.path}/build-count');
      final compiler = File('${directory.path}/compiler');
      compiler.writeAsStringSync('''#!/usr/bin/env python3
import pathlib,sys
if '--version' in sys.argv:
 print('fixture-compiler v1')
 sys.exit(0)
counter=pathlib.Path(${_pythonString(counter.path)})
counter.write_text(counter.read_text()+'x' if counter.exists() else 'x')
source=pathlib.Path(sys.argv[sys.argv.index('-fPIC')+1]).read_bytes()
if source==b'fail': sys.exit(1)
pathlib.Path(sys.argv[sys.argv.index('-o')+1]).write_bytes(source)
''');
      final mode = await Process.run('/bin/chmod', ['700', compiler.path]);
      expect(mode.exitCode, 0);
      final cache = Directory('${directory.path}/cache');
      final first = '${directory.path}/first.so';
      final second = '${directory.path}/second.so';
      Future<void> build(String output) => buildCachedNativeFixture(
        source: source.path,
        output: output,
        compiler: compiler.path,
        cacheRoot: cache,
      );
      await Future.wait([build(first), build(second)]);
      expect(counter.readAsStringSync(), 'x');
      File(first).writeAsStringSync('changed private copy');
      expect(File(second).readAsStringSync(), 'first source');
      source.writeAsStringSync('second source');
      await build(first);
      expect(counter.readAsStringSync(), 'xx');
      expect(File(first).readAsStringSync(), 'second source');
      source.writeAsStringSync('fail');
      await expectLater(build(first), throwsStateError);
      await expectLater(build(first), throwsStateError);
      expect(counter.readAsStringSync(), 'xxxx');
      expect(cache.listSync().whereType<Directory>(), isEmpty);
    },
    skip: Platform.isWindows ? 'Unix native fixture compiler' : false,
  );
}

String _pythonString(String value) => "r'${value.replaceAll("'", "\\'")}'";
