import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:foresight_core/src/native_diagnostics.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

Future<void> compile(String output, {bool legacy = false}) async {
  final process = await Process.start('c++', [
    '-std=c++20',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-shared',
    '-fPIC',
    '-I',
    Directory('../../native').absolute.path,
    if (legacy) '-DFORESIGHT_FIXTURE_LEGACY=1',
    'test/fixtures/native_diagnostics.cpp',
    '-o',
    output,
  ]);
  final out = utf8.decoder.bind(process.stdout).join();
  final err = utf8.decoder.bind(process.stderr).join();
  try {
    final result = await process.exitCode.timeout(const Duration(seconds: 30));
    expect(result, 0, reason: '${await out}\n${await err}');
  } finally {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 5));
    final captured = '${await out}\n${await err}';
    if (captured.trim().isNotEmpty) print(captured);
  }
}

void main() {
  late DynamicLibrary image;
  late NativeLibrary loaded;
  late int Function(int) enqueue;
  late void Function() configure;
  setUp(() async {
    final temp = createTestTempDirectorySync('native-diag-');
    final path = '${temp.path}/queue.${Platform.isMacOS ? 'dylib' : 'so'}';
    await compile(path);
    image = DynamicLibrary.open(path);
    loaded = NativeLibrary(image);
    enqueue = image.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'fs_test_enqueue',
    );
    configure = image.lookupFunction<Void Function(), void Function()>(
      'fs_test_configure',
    );
  });

  test('old native image disables only optional queue support', () async {
    final temp = createTestTempDirectorySync('native-legacy-');
    final path = '${temp.path}/legacy.${Platform.isMacOS ? 'dylib' : 'so'}';
    await compile(path, legacy: true);
    final legacy = NativeLibrary(DynamicLibrary.open(path));
    expect(NativeDiagnosticQueue.tryOpen(legacy), isNull);
    expect(legacy.library.providesSymbol('fs_abi_version'), isTrue);
  });

  test('pins before opening and has one explicit consumer', () {
    final pinCalls = image.lookupFunction<Int32 Function(), int Function()>(
      'fs_test_pin_calls',
    );
    expect(pinCalls(), 0);
    final queue = NativeDiagnosticQueue.tryOpen(loaded)!;
    addTearDown(() => expect(queue.close(), isTrue));
    expect(pinCalls(), 1);
    expect(NativeDiagnosticQueue.tryOpen(loaded), isNull);
    expect(queue.close(), isTrue);
    final replacement = NativeDiagnosticQueue.tryOpen(loaded)!;
    addTearDown(() => expect(replacement.close(), isTrue));
    expect(replacement.close(), isTrue);
    expect(queue.close(), isTrue);
  });

  test('refused original image pin creates no consumer', () {
    final pinResult = image
        .lookupFunction<Void Function(Int32), void Function(int)>(
          'fs_test_pin_result',
        );
    pinResult(0);
    expect(NativeDiagnosticQueue.tryOpen(loaded), isNull);
    pinResult(1);
    final queue = NativeDiagnosticQueue.tryOpen(loaded)!;
    addTearDown(() => expect(queue.close(), isTrue));
    expect(queue.close(), isTrue);
  });

  test('unsupported lifetime version never calls its dependent pin', () {
    image.lookupFunction<Void Function(Int32), void Function(int)>(
      'fs_test_pin_version',
    )(1);
    expect(NativeDiagnosticQueue.tryOpen(loaded), isNull);
    expect(
      image.lookupFunction<Int32 Function(), int Function()>(
        'fs_test_pin_calls',
      )(),
      0,
    );
  });

  test('priority overtakes then older ordinary and mixed records survive', () {
    final queue = NativeDiagnosticQueue.tryOpen(loaded)!;
    addTearDown(() => expect(queue.close(), isTrue));
    expect(enqueue(0), 0);
    configure();
    for (final priority in [0, 1, 0, 1]) {
      expect(enqueue(priority), 1);
    }
    final records = <NativeDiagnosticRecord>[];
    final priority = queue.poll(
      capacity: 1,
      priorityOnly: true,
      onRecord: (record) {
        records.add(record);
        return true;
      },
    )!;
    expect(priority.count, 1);
    final overtaking = records.single;
    expect(overtaking.priority, isTrue);
    expect(overtaking.category, 10);
    expect(overtaking.status, -1);
    expect(overtaking.signal, 9);
    expect(overtaking.bytes, 12);
    expect(overtaking.dropped, 3);
    records.clear();
    expect(
      queue
          .poll(
            capacity: 64,
            priorityOnly: false,
            onRecord: (record) {
              records.add(record);
              return true;
            },
          )!
          .count,
      3,
    );
    expect(records.map((r) => r.priority), [false, false, true]);
    expect(records.first.sequence, lessThan(overtaking.sequence));
    expect(records.first.queued, 4);
    expect(records.first.active, isTrue);
    expect(records.first.durationUs, 123);
    expect(queue.invalid, isFalse);
  });

  test('BUSY retains native ownership and buffers until retry', () {
    final queue = NativeDiagnosticQueue.tryOpen(loaded)!;
    final gate = image.lookupFunction<Void Function(Int32), void Function(int)>(
      'fs_test_gate',
    );
    addTearDown(() {
      gate(0);
      expect(queue.close(), isTrue);
    });
    gate(1);
    var exposed = 0;
    expect(
      queue.poll(
        capacity: 1,
        priorityOnly: false,
        onRecord: (_) {
          exposed++;
          return true;
        },
      ),
      isNull,
    );
    expect(exposed, 0);
    expect(queue.close(), isFalse);
    expect(queue.closed, isFalse);
    gate(0);
    expect(queue.close(), isTrue);
    expect(
      queue.poll(capacity: 1, priorityOnly: false, onRecord: (_) => true),
      isNull,
    );
  });

  test('rejects a malformed entire batch before exposing its prefix', () {
    final queue = NativeDiagnosticQueue.tryOpen(loaded)!;
    addTearDown(() => expect(queue.close(), isTrue));
    configure();
    expect(enqueue(0), 1);
    image.lookupFunction<Void Function(), void Function()>(
      'fs_test_malformed',
    )();
    var exposed = 0;
    expect(
      queue.poll(
        capacity: 64,
        priorityOnly: false,
        onRecord: (_) {
          exposed++;
          return true;
        },
      ),
      isNull,
    );
    expect(exposed, 0);
    expect(queue.invalid, isTrue);
    expect(
      queue.poll(capacity: 1, priorityOnly: false, onRecord: (_) => true),
      isNull,
    );
  });

  test('handles unsigned sequence and saturated counters without wrapping', () {
    final queue = NativeDiagnosticQueue.tryOpen(loaded)!;
    addTearDown(() => expect(queue.close(), isTrue));
    configure();
    image.lookupFunction<Void Function(), void Function()>(
      'fs_test_high_sequence',
    )();
    expect(enqueue(0), 1);
    final records = <NativeDiagnosticRecord>[];
    expect(
      queue
          .poll(
            capacity: 1,
            priorityOnly: false,
            onRecord: (record) {
              records.add(record);
              return true;
            },
          )!
          .count,
      1,
    );
    expect(records.single.sequence, isNegative);
    expect(enqueue(0), 1);
    image.lookupFunction<Void Function(), void Function()>(
      'fs_test_saturated_drops',
    )();
    final batch = queue.poll(
      capacity: 1,
      priorityOnly: false,
      onRecord: (record) {
        records.add(record);
        return true;
      },
    )!;
    expect(batch.count, 1);
    expect(batch.droppedPriority, 0x7fffffff);
    expect(batch.counterSaturated, isTrue);
    expect(queue.invalid, isFalse);
  });

  test('poll capacity checked before entering native code', () {
    final queue = NativeDiagnosticQueue.tryOpen(loaded)!;
    addTearDown(() => expect(queue.close(), isTrue));
    for (final capacity in [0, 65]) {
      expect(
        () => queue.poll(
          capacity: capacity,
          priorityOnly: false,
          onRecord: (_) => true,
        ),
        throwsRangeError,
      );
    }
  });

  test('clamping an unsaturated native counter explicitly loses precision', () {
    final queue = NativeDiagnosticQueue.tryOpen(loaded)!;
    addTearDown(() => expect(queue.close(), isTrue));
    image.lookupFunction<Void Function(), void Function()>(
      'fs_test_clamped_drops',
    )();
    final batch = queue.poll(
      capacity: 1,
      priorityOnly: false,
      onRecord: (_) => true,
    )!;
    expect(batch.droppedGeneral, 0x7fffffff);
    expect(batch.counterSaturated, isTrue);
    expect(batch.precisionLost, isFalse);
  });

  test(
    'producer contention preserves precision loss until one successful drain',
    () {
      final queue = NativeDiagnosticQueue.tryOpen(loaded)!;
      final gate = image
          .lookupFunction<Void Function(Int32), void Function(int)>(
            'fs_test_gate',
          );
      addTearDown(() {
        gate(0);
        expect(queue.close(), isTrue);
      });
      configure();
      gate(1);
      expect(enqueue(1), 0);
      expect(
        queue.poll(capacity: 1, priorityOnly: true, onRecord: (_) => true),
        isNull,
      );
      gate(0);
      final batch = queue.poll(
        capacity: 1,
        priorityOnly: true,
        onRecord: (_) => true,
      )!;
      expect(batch.count, 0);
      expect(batch.droppedPriority, 0);
      expect(batch.precisionLost, isTrue);
      expect(batch.counterSaturated, isFalse);
      expect(
        queue
            .poll(capacity: 1, priorityOnly: true, onRecord: (_) => true)!
            .precisionLost,
        isFalse,
      );
    },
  );

  for (final priority in [0, 1]) {
    for (final mode in [0, 1, 2]) {
      test(
        'rejects lane$priority sequence regression$mode before delivery',
        () {
          final queue = NativeDiagnosticQueue.tryOpen(loaded)!;
          addTearDown(() => expect(queue.close(), isTrue));
          configure();
          if (mode == 2) {
            image.lookupFunction<Void Function(), void Function()>(
              'fs_test_high_sequence',
            )();
          }
          expect(enqueue(priority), 1);
          expect(enqueue(priority), 1);
          expect(
            queue
                .poll(
                  capacity: 2,
                  priorityOnly: priority == 1,
                  onRecord: (_) => true,
                )!
                .count,
            2,
          );
          image.lookupFunction<
            Void Function(Int32, Int32),
            void Function(int, int)
          >('fs_test_bad_sequence')(priority, mode);
          var exposed = 0;
          expect(
            queue.poll(
              capacity: 1,
              priorityOnly: priority == 1,
              onRecord: (_) {
                exposed++;
                return true;
              },
            ),
            isNull,
          );
          expect(queue.invalid, isTrue);
          expect(exposed, 0);
        },
      );
    }
  }

  test(
    'delivery errors are counted and cannot interrupt or reenter a batch',
    () {
      final queue = NativeDiagnosticQueue.tryOpen(loaded)!;
      addTearDown(() => expect(queue.close(), isTrue));
      configure();
      for (var at = 0; at < 3; at++) {
        expect(enqueue(0), 1);
      }
      var delivered = 0;
      final batch = queue.poll(
        capacity: 3,
        priorityOnly: false,
        onRecord: (_) {
          expect(queue.close(), isFalse);
          expect(
            queue.poll(capacity: 1, priorityOnly: false, onRecord: (_) => true),
            isNull,
          );
          delivered++;
          if (delivered == 2) throw StateError('private callback canary');
          return delivered != 1;
        },
      )!;
      expect(batch.count, 3);
      expect(batch.deliveryDropped, 2);
      expect(delivered, 3);
      expect(queue.invalid, isFalse);
    },
  );
}
