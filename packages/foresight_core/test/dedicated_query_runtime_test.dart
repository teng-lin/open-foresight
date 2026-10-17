import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/src/dedicated_query_runtime.dart';

/// SIGKILL requests termination asynchronously. Hold exit completion separately
/// so this fixture detects returning from close before the owned worker is reaped.
class DeferredExitProcess implements Process {
  final exited = Completer<int>();
  final requested = Completer<void>();
  final output = StreamController<List<int>>();
  final input = StreamController<List<int>>();
  late final IOSink sink = IOSink(input.sink);
  bool killed = false;
  DeferredExitProcess() {
    input.stream.listen((_) {
      if (!requested.isCompleted) requested.complete();
    });
    output.add(utf8.encode('{"type":"ready"}\n'));
  }
  @override
  Future<int> get exitCode => exited.future;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => sink;
  @override
  int get pid => 12345;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }
}

void main() {
  late Directory directory;
  late String worker;
  late DedicatedQueryRuntime runtime;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('dedicated-query-');
    worker = '${directory.path}/worker.py';
    File(worker).writeAsStringSync('''
import json, os, sys, time
with open(sys.argv[-1], 'w') as output: output.write(str(os.getpid()))
print(json.dumps({'type':'ready'}), flush=True)
for line in sys.stdin:
    request=json.loads(line)
    if request['prompt']=='wait': time.sleep(60)
    if request['prompt']=='oversized':
        sys.stdout.write('x' * (1024 * 1024 + 1)); sys.stdout.flush(); time.sleep(60)
    if request['prompt']=='invalid-utf8':
        os.write(1, b'\\xff'); time.sleep(60)
    print(json.dumps({'type':'result','id':request['id'],'text':' Question?\\n'}), flush=True)
with open(sys.argv[-1] + '.exit', 'w') as output: output.write('eof')
''');
    runtime = DedicatedQueryRuntime(
      python: 'python3',
      worker: worker,
      model: '${directory.path}/pid',
      timeout: const Duration(seconds: 5),
    );
  });
  tearDown(() async {
    await runtime.close();
    directory.deleteSync(recursive: true);
  });

  Future<int> waitForPid() async {
    final file = File('${directory.path}/pid');
    for (var i = 0; i < 500; i++) {
      if (file.existsSync() && file.readAsStringSync().isNotEmpty) {
        return int.parse(file.readAsStringSync());
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('Test worker did not start');
  }

  test(
    'native worker launches directly and owns its process lifecycle',
    () async {
      await runtime.close();
      final process = DeferredExitProcess();
      runtime = DedicatedQueryRuntime(
        python: '/bundle/bin/foresight-query',
        worker: '/bundle/bin/foresight-query',
        model: '/profile/detector.tflite',
        startProcess: (executable, arguments) async {
          expect(executable, '/bundle/bin/foresight-query');
          expect(arguments, ['--model', '/profile/detector.tflite']);
          return process;
        },
      );
      final pending = runtime.complete(' <ctrl1>question', 'native');
      final failure = expectLater(pending, throwsStateError);
      await process.requested.future;
      runtime.cancel('native');
      await failure;
      process.exited.complete(-9);
      await runtime.close();
      await process.sink.close();
      await process.output.close();
    },
  );

  test(
    'reuses the dedicated process and preserves output whitespace',
    () async {
      expect(await runtime.complete('first', '1'), ' Question?\n');
      final first = await waitForPid();
      expect(await runtime.complete('second', '2'), ' Question?\n');
      expect(await waitForPid(), first);
    },
  );

  test(
    'cancellation owns its request, kills the process, and permits restart',
    () async {
      final pending = runtime.complete('wait', 'owned');
      final failure = expectLater(pending, throwsA(isA<StateError>()));
      final first = await waitForPid();
      runtime.cancel('someone-else');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await Process.run('kill', ['-0', '$first'])).exitCode, 0);
      runtime.cancel('owned');
      await failure;
      expect(await runtime.complete('next', 'new-owner'), ' Question?\n');
      expect(await waitForPid(), isNot(first));
      expect((await Process.run('kill', ['-0', '$first'])).exitCode, isNot(0));
    },
  );

  test(
    'bounded and malformed worker output fail only the owning process',
    () async {
      for (final prompt in ['oversized', 'invalid-utf8']) {
        await expectLater(
          runtime.complete(prompt, 'bad'),
          throwsA(isA<FormatException>()),
        );
        expect(await runtime.complete('next', 'good'), ' Question?\n');
      }
    },
  );

  test('idle close uses EOF and leaves no owned process', () async {
    await runtime.complete('first', 'owned');
    final pid = await waitForPid();
    await runtime.close();
    expect(File('${directory.path}/pid.exit').readAsStringSync(), 'eof');
    expect((await Process.run('kill', ['-0', '$pid'])).exitCode, isNot(0));
  });

  test('close during generation releases the owned process', () async {
    final pending = runtime.complete('wait', 'owned');
    final failure = expectLater(pending, throwsA(isA<StateError>()));
    final pid = await waitForPid();
    await runtime.close();
    await failure;
    expect((await Process.run('kill', ['-0', '$pid'])).exitCode, isNot(0));
    await expectLater(runtime.complete('new', 'next'), throwsStateError);
  });

  test('timeout kills an unresponsive owned worker', () async {
    await runtime.close();
    // Start the real worker before the short response deadline. Under coverage
    // or CPU contention, interpreter startup alone can exceed 150 ms.
    final process = await Process.start('python3', [
      '-I',
      '-B',
      worker,
      '--model',
      '${directory.path}/pid',
    ]);
    try {
      final pid = await waitForPid();
      runtime = DedicatedQueryRuntime(
        python: 'python3',
        worker: worker,
        model: '${directory.path}/pid',
        timeout: const Duration(milliseconds: 150),
        startProcess: (_, _) async => process,
      );
      await expectLater(
        runtime.complete('wait', 'owned'),
        throwsA(isA<TimeoutException>()),
      );
      await runtime.close();
      expect((await Process.run('kill', ['-0', '$pid'])).exitCode, isNot(0));
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  });

  test(
    'close waits for a previously cancelled owned process to finish exit',
    () async {
      await runtime.close();
      final process = DeferredExitProcess();
      runtime = DedicatedQueryRuntime(
        python: 'fixture',
        worker: worker,
        model: '${directory.path}/pid',
        startProcess: (_, _) async => process,
      );
      final pending = runtime.complete('wait', 'owned');
      final failed = expectLater(pending, throwsStateError);
      await process.requested.future;
      runtime.cancel('owned');
      await failed;
      expect(process.killed, isTrue);
      var closed = false;
      final closing = runtime.close().then((_) {
        closed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      process.exited.complete(-9);
      await closing;
      expect(closed, isTrue);
      await process.sink.close();
      await process.output.close();
    },
  );
}
