import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:foresight_core/src/application_services/audio_storage_headroom.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

final class ControlledProbe implements AudioStorageSpaceProbe {
  final samples = <Completer<int?>>[];
  bool disposed = false;
  @override
  bool get busy => samples.any((s) => !s.isCompleted);
  @override
  bool get restartRequired => false;
  @override
  Future<int?> sample(String directory) {
    final sample = Completer<int?>();
    samples.add(sample);
    return sample.future;
  }

  @override
  Future<void> close() async {
    disposed = true;
    for (final sample in samples) {
      if (!sample.isCompleted) sample.complete(null);
    }
  }
}

final class DiscardInput implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  Future<void> close() async {}
}

final class ControlledProcess implements Process {
  final output = StreamController<List<int>>(onCancel: () async {});
  final errors = StreamController<List<int>>(onCancel: () async {});
  final exited = Completer<int>();
  final signals = <ProcessSignal>[];
  bool exitOnTerm = true, exitOnKill = true;
  @override
  IOSink get stdin {
    final sink = IOSink(DiscardInput());
    sink.close().ignore();
    return sink;
  }

  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => 12345;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if ((signal == ProcessSignal.sigterm && exitOnTerm) ||
        (signal == ProcessSignal.sigkill && exitOnKill)) {
      finish(-9);
    }
    return true;
  }

  void finish(int code, {String text = ''}) {
    if (exited.isCompleted) return;
    if (text.isNotEmpty) output.add(utf8.encode(text));
    output.close().ignore();
    errors.close().ignore();
    exited.complete(code);
  }
}

const good =
    'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    'disk 1000000 100 999900 1% /private path\n';

void main() {
  test('two raw routes plus headers and native reserve determine estimate', () {
    expect(estimatedAudioRecordingUs(null), isNull);
    expect(estimatedAudioRecordingUs(-1), isNull);
    expect(estimatedAudioRecordingUs(audioStorageReserveBytes - 1), 0);
    expect(estimatedAudioRecordingUs(audioStorageReserveBytes), 0);
    expect(
      estimatedAudioRecordingUs(audioStorageReserveBytes + 192080),
      1000000,
    );
    expect(estimatedAudioRecordingUs(audioStorageReserveBytes + 96040), 500000);
    expect(estimatedAudioRecordingUs(0x7fffffffffffffff), 0x7fffffffffffffff);
  });

  test(
    'POSIX free-space parse rejects ambiguous, negative and excessive data',
    () {
      expect(parseAudioStorageAvailableBytes(good), 999900 * 1024);
      expect(parseAudioStorageAvailableBytes(''), isNull);
      expect(parseAudioStorageAvailableBytes('$good\nextra'), isNull);
      expect(
        parseAudioStorageAvailableBytes(good.replaceFirst('999900', '-1')),
        isNull,
      );
      expect(
        parseAudioStorageAvailableBytes(good.replaceFirst('999900', 'x')),
        isNull,
      );
      expect(
        parseAudioStorageAvailableBytes(
          good.replaceFirst('999900', '9223372036854775807'),
        ),
        isNull,
      );
    },
  );

  test(
    'reads coalesce, refresh throttles, stale and failed samples are unknown',
    () async {
      var now = 0;
      final probe = ControlledProbe();
      final cache = AudioStorageHeadroom(
        directory: '/owned/recordings',
        scope: () => 'epoch:generation',
        nowUs: () => now,
        changed: () {},
        probe: probe,
      );
      expect(cache.estimatedRemainingRecordingUs, isNull);
      expect(cache.estimatedRemainingRecordingUs, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(probe.samples, hasLength(1));
      probe.samples.single.complete(audioStorageReserveBytes + 1920800);
      await Future<void>.delayed(Duration.zero);
      expect(cache.estimatedRemainingRecordingUs, 10000000);
      now = 4999999;
      expect(cache.estimatedRemainingRecordingUs, 10000000);
      expect(probe.samples, hasLength(1));
      now = 5000000;
      expect(cache.estimatedRemainingRecordingUs, 10000000);
      await Future<void>.delayed(Duration.zero);
      expect(probe.samples, hasLength(2));
      now = 15000000;
      expect(cache.estimatedRemainingRecordingUs, isNull);
      expect(probe.samples, hasLength(2));
      probe.samples.last.complete(null);
      await Future<void>.delayed(Duration.zero);
      expect(cache.estimatedRemainingRecordingUs, isNull);
      await cache.close();
      expect(probe.disposed, isTrue);
    },
  );

  test(
    'workspace/generation change rejects a late sample and disposal prevents refresh',
    () async {
      var scope = 'old:old';
      var now = 0, notifications = 0;
      final probe = ControlledProbe();
      final cache = AudioStorageHeadroom(
        directory: '/owned/recordings',
        scope: () => scope,
        nowUs: () => now,
        changed: () => notifications++,
        probe: probe,
      );
      expect(cache.estimatedRemainingRecordingUs, isNull);
      await Future<void>.delayed(Duration.zero);
      scope = 'new:new';
      probe.samples.single.complete(audioStorageReserveBytes + 192080);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 0);
      expect(cache.estimatedRemainingRecordingUs, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(probe.samples, hasLength(2));
      probe.samples.last.complete(audioStorageReserveBytes);
      await Future<void>.delayed(Duration.zero);
      expect(cache.estimatedRemainingRecordingUs, 0);
      now = -1;
      expect(cache.estimatedRemainingRecordingUs, isNull);
      await cache.close();
      now = 100000000;
      expect(cache.estimatedRemainingRecordingUs, isNull);
    },
  );

  test(
    'utility success requires actual exit and both streams within bounds',
    () async {
      final process = ControlledProcess();
      final probe = AudioStorageProcessProbe(
        startProcess: (executable, args) async {
          expect(executable, Platform.isMacOS ? '/bin/df' : '/usr/bin/df');
          expect(args, ['-Pk', '/owned/recordings']);
          return process;
        },
      );
      var settled = false;
      final sample = probe.sample('/owned/recordings').then((value) {
        settled = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      process.output.add(utf8.encode(good));
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      process.finish(0);
      expect(await sample, 999900 * 1024);
      expect(probe.busy, isFalse);
      await probe.close();
    },
  );

  test(
    'excess output stops and reaps utility instead of retaining its bytes',
    () async {
      final process = ControlledProcess();
      final probe = AudioStorageProcessProbe(
        startProcess: (_, _) async => process,
      );
      final sample = probe.sample('/owned/recordings');
      await Future<void>.delayed(Duration.zero);
      process.output.add(List.filled(16385, 65));
      expect(await sample, isNull);
      expect(process.signals, contains(ProcessSignal.sigterm));
      expect(probe.busy, isFalse);
      await probe.close();
    },
  );

  test('timeout escalates TERM to KILL and waits actual child exit', () {
    fakeAsync((clock) {
      final process = ControlledProcess()..exitOnTerm = false;
      final probe = AudioStorageProcessProbe(
        timeout: const Duration(milliseconds: 20),
        terminateGrace: const Duration(milliseconds: 5),
        killGrace: const Duration(milliseconds: 10),
        startProcess: (_, _) async => process,
      );
      var completed = false;
      probe.sample('/owned/recordings').then((value) {
        expect(value, isNull);
        completed = true;
      }).ignore();
      clock.flushMicrotasks();
      clock.elapse(const Duration(milliseconds: 20));
      expect(completed, isFalse);
      expect(process.signals, [ProcessSignal.sigterm]);
      clock.elapse(const Duration(milliseconds: 5));
      expect(process.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      expect(completed, isTrue);
      expect(probe.restartRequired, isFalse);
      probe.close().ignore();
      clock.flushMicrotasks();
    });
  });

  test(
    'late launch remains owned after bounded refusal and is retired on arrival',
    () {
      fakeAsync((clock) {
        final launch = Completer<Process>();
        final probe = AudioStorageProcessProbe(
          timeout: const Duration(milliseconds: 20),
          terminateGrace: const Duration(milliseconds: 5),
          killGrace: const Duration(milliseconds: 10),
          startProcess: (_, _) => launch.future,
        );
        var completed = false;
        probe.sample('/owned/recordings').then((value) {
          expect(value, isNull);
          completed = true;
        }).ignore();
        clock.elapse(const Duration(milliseconds: 30));
        expect(completed, isTrue);
        expect(probe.restartRequired, isTrue);
        expect(probe.busy, isTrue);
        final process = ControlledProcess();
        launch.complete(process);
        clock.flushMicrotasks();
        expect(process.signals, [ProcessSignal.sigterm]);
        expect(probe.busy, isFalse);
        probe.close().ignore();
        clock.flushMicrotasks();
      });
    },
  );

  test('unconfirmed probe exit refuses close and retains its owner', () {
    fakeAsync((clock) {
      final process = ControlledProcess()
        ..exitOnTerm = false
        ..exitOnKill = false;
      final probe = AudioStorageProcessProbe(
        timeout: const Duration(milliseconds: 20),
        terminateGrace: const Duration(milliseconds: 5),
        killGrace: const Duration(milliseconds: 10),
        startProcess: (_, _) async => process,
      );
      probe.sample('/owned/recordings').ignore();
      clock.elapse(const Duration(milliseconds: 35));
      expect(probe.restartRequired, isTrue);
      expect(probe.busy, isTrue);
      var refused = false;
      probe
          .close()
          .then(
            (_) {
              throw StateError('Unknown child cannot be declared closed');
            },
            onError: (Object _) {
              refused = true;
            },
          )
          .ignore();
      clock.flushMicrotasks();
      expect(refused, isTrue);
      process.finish(-9);
      clock.flushMicrotasks();
    });
  });

  test(
    'nonzero exit and rejected launch return unknown after settlement',
    () async {
      final process = ControlledProcess();
      final probe = AudioStorageProcessProbe(
        startProcess: (_, _) async => process,
      );
      final sample = probe.sample('/owned/recordings');
      await Future<void>.delayed(Duration.zero);
      process.finish(1, text: good);
      expect(await sample, isNull);
      expect(probe.restartRequired, isFalse);
      await probe.close();
      final rejected = AudioStorageProcessProbe(
        startProcess: (_, _) => Future.error(StateError('launch refused')),
      );
      expect(await rejected.sample('/owned/recordings'), isNull);
      expect(rejected.busy, isFalse);
      await rejected.close();
    },
  );

  test(
    'actual timed-out child is terminated and reaped before sample settles',
    () async {
      Process? child;
      final probe = AudioStorageProcessProbe(
        timeout: const Duration(milliseconds: 20),
        startProcess: (_, _) async => child = await Process.start(
          '/bin/sleep',
          ['30'],
          includeParentEnvironment: false,
          environment: const {'LC_ALL': 'C'},
        ),
      );
      addTearDown(probe.close);
      expect(await probe.sample('/unused-by-controlled-launch'), isNull);
      expect(child, isNotNull);
      expect(await child!.exitCode, isNot(0));
      expect(probe.busy, isFalse);
      expect(probe.restartRequired, isFalse);
    },
  );

  test(
    'actual fixed utility reads the private recording filesystem and exits',
    () async {
      final directory = createTestTempDirectorySync('audio-space-');
      final probe = AudioStorageProcessProbe();
      addTearDown(probe.close);
      final bytes = await probe.sample(directory.path);
      expect(bytes, isNotNull);
      expect(bytes, greaterThanOrEqualTo(0));
      expect(probe.busy, isFalse);
      expect(probe.restartRequired, isFalse);
    },
  );
}
