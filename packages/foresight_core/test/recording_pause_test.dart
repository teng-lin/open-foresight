import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/application.dart';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:async';
import 'package:clock/clock.dart';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/remote_domain.dart' show RemoteRecording;

void main() {
  late Directory directory;
  late String library, model;
  late DynamicLibrary fixture;
  setUpAll(() async {
    directory = createTestTempDirectorySync('recording-pause-');
    library = '${directory.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    await buildCachedNativeFixture(
      source: 'test/fixtures/recording_native_stub.cpp',
      output: library,
    );
    fixture = DynamicLibrary.open(library);
    model = '${directory.path}/model';
    File(model).writeAsStringSync('ABI fixture only');
  });
  setUpAll(() {
    addTearDown(() => directory.deleteSync(recursive: true));
  });
  void fail(int channel) =>
      fixture.lookupFunction<Void Function(Int32), void Function(int)>(
        'fixture_fail_channel',
      )(channel);
  int emitEvent(int channel, Map<String, Object> value) {
    final event = jsonEncode(value).toNativeUtf8();
    try {
      return fixture.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>)
      >('fixture_emit')(channel, event);
    } finally {
      calloc.free(event);
    }
  }

  void holdSpeech(bool hold) =>
      fixture.lookupFunction<Void Function(Int32), void Function(int)>(
        'fixture_hold_speech',
      )(hold ? 1 : 0);
  void queueSpeech(bool queued) =>
      fixture.lookupFunction<Void Function(Int32), void Function(int)>(
        'fixture_queue_speech',
      )(queued ? 1 : 0);
  void admitSpeech(int handle, {bool complete = true}) => fixture
      .lookupFunction<Void Function(Uint64, Int32), void Function(int, int)>(
        'fixture_admit_speech',
      )(handle, complete ? 1 : 0);
  int admissionsPolled() =>
      fixture.lookupFunction<Int32 Function(), int Function()>(
        'fixture_speech_admissions_polled',
      )();
  Future<void> until(bool Function() ready) async {
    final elapsed = Stopwatch()..start();
    while (!ready()) {
      if (elapsed.elapsed > const Duration(seconds: 3)) {
        throw TestFailure('Speech fixture condition did not settle');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  int emit(int channel, int marker, {int count = 2000}) {
    final bytes = ByteData(count * 2);
    for (var i = 0; i < count; i++) {
      bytes.setInt16(i * 2, marker, Endian.little);
    }
    return emitEvent(channel, {
      'type': 'pcm',
      'sampleRate': 1000,
      'volume': .02,
      'data': base64Encode(bytes.buffer.asUint8List()),
    });
  }

  test(
    'installed capture supplies the canonical runtime to its native ABI',
    () async {
      final environment = Map.of(runtimeConfiguration.environment);
      addTearDown(
        () => runtimeConfiguration.environment
          ..clear()
          ..addAll(environment),
      );
      runtimeConfiguration.environment['FORESIGHT_INSTALL_ROOT'] =
          directory.path;
      final runner = File(
        '/usr/bin/true',
      ).copySync('${directory.path}/speech-runner');
      final alias = Link('${directory.path}/speech-alias')
        ..createSync(runner.path);
      final recording = Recording(library, (_) {}, (_, _, _, _) {});
      addTearDown(() async {
        recording.dispose();
        await recording.closed;
      });
      await recording.start(alias.path, model, playback: false);
      final selected = fixture
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'fixture_speech_runtime',
          )()
          .toDartString();
      expect(selected, runner.resolveSymbolicLinksSync());
    },
  );

  test('disposing during finalization returns an owned cancellation', () async {
    fail(-1);
    holdSpeech(true);
    addTearDown(() => holdSpeech(false));
    final recording = Recording(library, (_) {}, (_, _, _, _) {});
    addTearDown(() async {
      recording.dispose();
      await recording.closed;
    });
    await expectLater(
      recording.pause(),
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.notFound),
      ),
    );
    await recording.start('/usr/bin/true', model, playback: false);
    await expectLater(
      recording.start('/usr/bin/true', model, playback: false),
      throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy)),
    );
    emit(0, 222, count: 20000);
    recording.drain();
    final pending = recording.stop();
    final rejected = expectLater(
      pending,
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
      ),
    );
    await expectLater(
      recording.stop(),
      throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy)),
    );
    await expectLater(
      recording.pause(),
      throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy)),
    );
    await expectLater(
      recording.resume(),
      throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy)),
    );
    recording.dispose();
    await recording.closed;
    await rejected;
  });

  test(
    'startup observer disposal cannot create a late capture timer',
    () async {
      fail(-1);
      late Recording recording;
      recording = Recording(library, (state) {
        if (state.startsWith('Listening')) recording.dispose();
      }, (_, _, _, _) {});
      try {
        await expectLater(
          recording.start('/usr/bin/true', model),
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.cancelled,
            ),
          ),
        );
        await recording.closed;
        expect(recording.timer, isNull);
        expect(recording.captures, isEmpty);
        expect(recording.speeches, isEmpty);
        expect(emit(0, 999), 0);
        expect(emit(1, 999), 0);
      } finally {
        recording.timer?.cancel();
        recording.dispose();
        await recording.closed;
      }
    },
  );

  test(
    'done cannot reuse a speech handle before its actual worker join',
    () async {
      fail(-1);
      holdSpeech(false);
      queueSpeech(false);
      final holdJoin = fixture
          .lookupFunction<Void Function(Int32), void Function(int)>(
            'fixture_hold_speech_join',
          );
      final requests = fixture.lookupFunction<Int32 Function(), int Function()>(
        'fixture_speech_requests',
      );
      final before = requests();
      final rows = <String>[];
      final recording = Recording(
        library,
        (_) {},
        (text, _, _, _) => rows.add(text),
      );
      try {
        await recording.start('/usr/bin/true', model, playback: false);
        holdJoin(1);
        expect(emit(0, 111, count: 20000), 1);
        recording.drain();
        await until(() => rows.length == 1);
        expect(recording.speeches, hasLength(1));
        expect(emit(0, 222, count: 20000), 1);
        recording.drain();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(
          requests() - before,
          1,
          reason: 'A done frame cannot admit the next request',
        );
        holdJoin(0);
        await until(() => rows.length == 2);
        expect(requests() - before, 2);
        expect(rows, ['marker_111', 'marker_222']);
        await recording.stop();
      } finally {
        holdJoin(0);
        recording.dispose();
        await recording.closed;
      }
    },
  );

  test(
    'dispose returns promptly but closed joins a held speech worker',
    () async {
      fail(-1);
      holdSpeech(false);
      queueSpeech(false);
      final holdJoin = fixture
          .lookupFunction<Void Function(Int32), void Function(int)>(
            'fixture_hold_speech_join',
          );
      final rows = <String>[];
      final recording = Recording(
        library,
        (_) {},
        (text, _, _, _) => rows.add(text),
      );
      try {
        await recording.start('/usr/bin/true', model, playback: false);
        holdJoin(1);
        expect(emit(0, 333, count: 20000), 1);
        recording.drain();
        await until(() => rows.length == 1);
        final elapsed = Stopwatch()..start();
        recording.dispose();
        expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 100)));
        final completion = recording.closed;
        recording.dispose();
        expect(recording.closed, same(completion));
        expect(recording.captures, isEmpty);
        expect(recording.speeches, isEmpty);
        var joined = false;
        final settled = completion.then((_) => joined = true);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(
          joined,
          isFalse,
          reason: 'Retirement still owns the held native worker',
        );
        holdJoin(0);
        await settled;
        expect(rows, ['marker_333']);
        expect(emit(0, 999), 0);
      } finally {
        holdJoin(0);
        recording.dispose();
        await recording.closed;
      }
    },
  );

  for (final stopLimit in [Duration.zero, const Duration(milliseconds: 60)]) {
    test(
      'live segments reuse their native speech handle until recording stops',
      () async {
        final creations = fixture
            .lookupFunction<Int32 Function(), int Function()>(
              'fixture_speech_creations',
            );
        final before = creations();
        final rows = <String>[];
        final recording = Recording(
          library,
          (_) {},
          (text, _, __, ___) => rows.add(text),
        );
        try {
          await recording.start('/usr/bin/true', model, playback: false);
          for (var segment = 0; segment < 3; segment++) {
            emit(0, 100 + segment, count: 20000);
            recording.drain();
            final deadline = DateTime.now().add(const Duration(seconds: 2));
            while (rows.length <= segment &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            expect(rows.length, segment + 1);
          }
          expect(
            creations() - before,
            2,
            reason: 'One startup probe and one retained speech handle',
          );
          await recording.stop();
        } finally {
          recording.dispose();
          await recording.closed;
        }
      },
    );
    test(
      'hung speech stop limit ${stopLimit.inMilliseconds} ms retains committed text',
      () async {
        fail(-1);
        holdSpeech(false);
        final rows = <String>[];
        final gaps = <Map<String, dynamic>>[];
        final recording = Recording(
          library,
          (_) {},
          (text, _, _, _) => rows.add(text),
          speechTimeout: const Duration(seconds: 10),
          stopTimeout: stopLimit,
          interruption: gaps.add,
        );
        try {
          await recording.start('/usr/bin/true', model, playback: false);
          emit(0, 111, count: 20000);
          recording.drain();
          final deadline = DateTime.now().add(const Duration(seconds: 2));
          while (rows.isEmpty && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(rows, ['marker_111']);
          holdSpeech(true);
          emit(0, 222, count: 20000);
          recording.drain();
          final elapsed = Stopwatch()..start();
          await expectLater(recording.stop(), throwsStateError);
          expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
          expect(rows, ['marker_111']);
          expect(gaps.last['reason'], 'speech_stop_timeout');
          expect(recording.speeches, isEmpty);
        } finally {
          holdSpeech(false);
          recording.dispose();
          await recording.closed;
        }
      },
    );
  }

  test(
    'a stalled segment times out independently while recording remains stoppable',
    () async {
      fail(-1);
      holdSpeech(true);
      final gaps = <Map<String, dynamic>>[];
      final recording = Recording(
        library,
        (_) {},
        (_, _, _, _) {},
        speechTimeout: const Duration(milliseconds: 40),
        stopTimeout: const Duration(seconds: 1),
        interruption: gaps.add,
      );
      try {
        await recording.start('/usr/bin/true', model, playback: false);
        emit(0, 333, count: 20000);
        recording.drain();
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (gaps.isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(gaps.single['reason'], 'speech_recognition_error');
        expect(gaps.single['discarded_bytes'], 40000);
        await expectLater(recording.stop(), throwsStateError);
      } finally {
        holdSpeech(false);
        recording.dispose();
        await recording.closed;
      }
    },
  );

  test(
    'queued channels retain full execution credit after worker admission',
    () async {
      fail(-1);
      holdSpeech(false);
      queueSpeech(true);
      addTearDown(() => queueSpeech(false));
      final rows = <String>[];
      final gaps = <Map<String, dynamic>>[];
      final recording = Recording(
        library,
        (_) {},
        (text, _, __, source) => rows.add('$source:$text'),
        speechTimeout: const Duration(milliseconds: 40),
        speechQueueTimeout: const Duration(seconds: 2),
        interruption: gaps.add,
      );
      addTearDown(() async {
        recording.dispose();
        await recording.closed;
      });
      await recording.start('/usr/bin/true', model);
      emit(0, 111, count: 20000);
      emit(1, 222, count: 20000);
      recording.drain();
      await until(() => recording.speeches.length == 2 || gaps.isNotEmpty);
      final handles = recording.speeches.toList();
      expect(handles, hasLength(2));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        gaps,
        isEmpty,
        reason: 'Queue time cannot consume execution credit',
      );
      expect(rows, isEmpty);
      admitSpeech(handles[0]);
      await until(() => rows.isNotEmpty || gaps.isNotEmpty);
      expect(gaps, isEmpty);
      admitSpeech(handles[1]);
      await until(() => rows.length == 2 || gaps.isNotEmpty);
      expect(
        rows,
        unorderedEquals(['microphone:marker_111', 'playback:marker_222']),
      );
      expect(gaps, isEmpty);
      await recording.stop();
    },
  );

  test('queue admission has a finite independent deadline', () async {
    fail(-1);
    holdSpeech(false);
    queueSpeech(true);
    addTearDown(() => queueSpeech(false));
    final gaps = <Map<String, dynamic>>[];
    final recording = Recording(
      library,
      (_) {},
      (_, __, ___, ____) {},
      speechTimeout: const Duration(seconds: 2),
      speechQueueTimeout: const Duration(milliseconds: 40),
      interruption: gaps.add,
    );
    addTearDown(() async {
      recording.dispose();
      await recording.closed;
    });
    await recording.start('/usr/bin/true', model, playback: false);
    emit(0, 333, count: 20000);
    recording.drain();
    await until(() => gaps.isNotEmpty);
    expect(gaps.single['message'], contains('queue admission timed out'));
    expect(recording.speeches, isEmpty);
    await expectLater(recording.stop(), throwsStateError);
  });

  test(
    'execution remains finite and repeated admission cannot renew its credit',
    () async {
      fail(-1);
      holdSpeech(false);
      queueSpeech(true);
      addTearDown(() => queueSpeech(false));
      final gaps = <Map<String, dynamic>>[];
      final interrupted = Completer<bool>();
      final recording = Recording(
        library,
        (_) {},
        (_, __, ___, ____) {},
        speechTimeout: const Duration(milliseconds: 600),
        speechQueueTimeout: const Duration(seconds: 5),
        interruption: (gap) {
          gaps.add(gap);
          if (!interrupted.isCompleted) interrupted.complete(true);
        },
      );
      addTearDown(() async {
        recording.dispose();
        await recording.closed;
      });
      await recording.start('/usr/bin/true', model, playback: false);
      emit(0, 444, count: 20000);
      recording.drain();
      await until(() => recording.speeches.isNotEmpty);
      final handle = recording.speeches.single;
      // Remain queued longer than the execution allowance, then start execution.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(gaps, isEmpty);
      final beforeAdmission = admissionsPolled();
      expect(recording.speeches, contains(handle));
      admitSpeech(handle, complete: false);
      // Observe actual poll consumption, rather than merely placing a frame in
      // the fixture queue, before starting the repeated-admission window.
      await until(
        () => admissionsPolled() > beforeAdmission || gaps.isNotEmpty,
      );
      expect(gaps, isEmpty);
      final renewals = Timer.periodic(const Duration(milliseconds: 50), (_) {
        // Timeout can release the pointer between timer callbacks. Only the
        // current Recording owner may submit another fixture event.
        if (recording.speeches.contains(handle)) {
          admitSpeech(handle, complete: false);
        }
      });
      // Five execution budgets: resetting the clock on each admission must fail
      // while renewals still run, rather than time out after they have stopped.
      final renewalWindow = Timer(const Duration(seconds: 3), () {
        if (!interrupted.isCompleted) interrupted.complete(false);
      });
      try {
        expect(
          await interrupted.future,
          true,
          reason: 'Execution must time out while repeated admissions continue',
        );
        expect(renewals.isActive, true);
        expect(
          admissionsPolled() - beforeAdmission,
          greaterThanOrEqualTo(3),
          reason: 'Repeated admission frames must actually reach the consumer',
        );
      } finally {
        renewals.cancel();
        renewalWindow.cancel();
      }
      expect(gaps.single['message'], contains('Speech worker timed out'));
      expect(gaps.single['message'], isNot(contains('queue admission')));
      expect(recording.speeches, isEmpty);
      await expectLater(recording.stop(), throwsStateError);
    },
  );

  for (final pause in [false, true]) {
    test(
      'a late speech hypothesis cannot reappear after ${pause ? "pause/resume" : "a route gap"}',
      () async {
        fail(-1);
        holdSpeech(true);
        final provisional = <String>[];
        final rows = <String>[];
        final recording = Recording(
          library,
          (_) {},
          (text, _, _, _) => rows.add(text),
          provisional: (text, _, _, _) => provisional.add(text),
        );
        try {
          await recording.start('/usr/bin/true', model, playback: false);
          emit(0, 123, count: 5000);
          recording.drain();
          final deadline = DateTime.now().add(const Duration(seconds: 2));
          while (recording.speeches.isEmpty &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(recording.speeches, hasLength(1));
          if (pause) {
            await recording.pause();
            await recording.resume();
          } else {
            emitEvent(0, {'type': 'gap', 'reason': 'audio_device_changed'});
            recording.drain();
          }
          holdSpeech(false);
          await recording.stop();
          expect(provisional.where((text) => text.isNotEmpty), isEmpty);
          expect(rows, ['marker_123']);
        } finally {
          holdSpeech(false);
          recording.dispose();
          await recording.closed;
        }
      },
    );
  }

  test(
    'route loss clears stale levels, hypotheses and AEC until recovery',
    () async {
      fail(-1);
      final provisional = <String>[];
      final rows = <String>[];
      final states = <String>[];
      final recording = Recording(
        library,
        states.add,
        (text, _, _, _) => rows.add(text),
        provisional: (text, _, _, source) => provisional.add('$source:$text'),
      );
      try {
        await recording.start('/usr/bin/true', model, echoCancellation: true);
        emit(0, 123);
        emit(1, 456);
        recording.drain();
        expect(recording.echoCancellationState['active'], true);
        expect(recording.currentVolumes, [.02, .02]);

        emitEvent(0, {'type': 'gap', 'reason': 'audio_device_changed'});
        recording.drain();
        expect(recording.currentVolumes, [0, .02]);
        expect(provisional, contains('microphone:'));
        expect(recording.echoCancellationState['active'], false);
        expect(recording.echoCancellationState['pending'], true);
        emitEvent(0, {
          'type': 'echo_cancellation',
          'active': true,
          'fallback_status': 0,
        });
        recording.drain();
        expect(recording.echoCancellationState['active'], true);

        emitEvent(0, {'type': 'gap', 'reason': 'capture_buffer_overflow'});
        recording.drain();
        expect(recording.echoCancellationState['active'], true);
        emitEvent(1, {
          'type': 'state',
          'state': 'failed',
          'message': 'device lost',
        });
        emitEvent(0, {'type': 'error', 'message': 'engine failed'});
        emitEvent(0, {'type': 'state', 'state': 'stopped'});
        recording.drain();
        expect(recording.currentVolumes, [0, 0]);
        expect(provisional, contains('playback:'));
        expect(recording.echoCancellationState['active'], false);
        expect(recording.echoCancellationState['pending'], false);
        expect(states, contains('Microphone capture failed: engine failed'));
        expect(states.last, contains('device lost'));
        await expectLater(recording.stop(), throwsStateError);
        expect(rows, unorderedEquals(['marker_123', 'marker_456']));
      } finally {
        recording.dispose();
        await recording.closed;
      }
    },
  );

  test(
    'echo processing survives bypass, pause and resume without changing routes',
    () async {
      fail(-1);
      final recording = Recording(library, (_) {}, (_, _, _, _) {});
      try {
        await recording.start('/usr/bin/true', model, echoCancellation: true);
        recording.drain();
        expect(recording.echoCancellationState['active'], true);
        recording.setEchoCancellation(false);
        recording.drain();
        expect(recording.echoCancellationState['active'], false);
        recording.setEchoCancellation(true);
        recording.drain();
        expect(recording.echoCancellationState['active'], true);
        await recording.pause();
        expect(recording.echoCancellationState['active'], false);
        await recording.resume();
        expect(recording.echoCancellationState['active'], false);
        expect(recording.echoCancellationState['pending'], true);
        recording.drain();
        expect(recording.echoCancellationState['active'], true);
        await recording.stop();
        expect(recording.echoCancellationState['active'], false);
      } finally {
        recording.dispose();
        await recording.closed;
      }
    },
  );

  test(
    'enabling a standard engine reports restart and fallback never claims processing',
    () async {
      fail(-1);
      final states = <String>[];
      final recording = Recording(library, states.add, (_, _, _, _) {});
      try {
        await recording.start('/usr/bin/true', model);
        recording.setEchoCancellation(true);
        recording.drain();
        expect(recording.echoCancellationState['requested'], true);
        expect(recording.echoCancellationState['active'], false);
        expect(recording.echoCancellationState['restart_required'], true);
        expect(states.last, contains('Restart recording'));
        final fallback = jsonEncode({
          'type': 'echo_cancellation',
          'active': false,
          'fallback_status': -1,
        }).toNativeUtf8();
        try {
          fixture.lookupFunction<
            Int32 Function(Int32, Pointer<Utf8>),
            int Function(int, Pointer<Utf8>)
          >('fixture_emit')(0, fallback);
        } finally {
          calloc.free(fallback);
        }
        recording.drain();
        expect(recording.echoCancellationState['active'], false);
        expect(states.last, contains('continuing with standard'));
        expect(recording.lastError, isEmpty);
        emitEvent(0, {
          'type': 'echo_cancellation',
          'active': false,
          'fallback_status': 0,
          'fallback_reason': 'tap_startup_timeout',
        });
        recording.drain();
        expect(recording.echoCancellationState['active'], false);
        expect(
          recording.echoCancellationState['fallback_reason'],
          'tap_startup_timeout',
        );
        expect(states.last, contains('continuing with standard'));
        expect(recording.lastError, isEmpty);
        await recording.stop();
      } finally {
        recording.dispose();
        await recording.closed;
      }
    },
  );

  test(
    'pause releases both devices, retains queued tail, and resumed timing excludes paused audio',
    () async {
      final rows = <Map<String, Object>>[];
      final states = <String>[];
      final recording = Recording(
        library,
        states.add,
        (text, start, end, source) => rows.add({
          'text': text,
          'start': start,
          'end': end,
          'source': source,
        }),
      );
      try {
        await recording.start('/usr/bin/true', model);
        emit(0, 100);
        emit(1, 200);
        await recording
            .pause(); // Deliberately leave PCM queued until Pause drains it.
        expect(recording.paused, true);
        expect(recording.captures, isEmpty);
        expect(recording.currentVolumes, [0, 0]);
        expect(emit(0, 999), 0);
        expect(emit(1, 999), 0);
        await expectLater(
          recording.start('/usr/bin/true', model),
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.busy,
            ),
          ),
        );
        await recording.pause(); // Idempotent pause preserves pending work.
        await recording.resume();
        expect(recording.paused, false);
        expect(recording.captures, hasLength(2));
        emit(0, 300);
        emit(1, 400);
        await recording.stop();
        expect(
          rows,
          unorderedEquals([
            {
              'text': 'marker_100',
              'start': 0,
              'end': 2000,
              'source': 'microphone',
            },
            {
              'text': 'marker_200',
              'start': 0,
              'end': 2000,
              'source': 'playback',
            },
            {
              'text': 'marker_300',
              'start': 2000,
              'end': 4000,
              'source': 'microphone',
            },
            {
              'text': 'marker_400',
              'start': 2000,
              'end': 4000,
              'source': 'playback',
            },
          ]),
        );
        expect(states, contains('Transcription paused'));
        expect(recording.captures, isEmpty);
        expect(recording.speeches, isEmpty);
        expect(recording.paused, false);
      } finally {
        recording.dispose();
        await recording.closed;
      }
    },
  );

  test(
    'failed resume releases partial channels, remains paused, and allows retry or Stop',
    () async {
      final text = <String>[];
      final recording = Recording(
        library,
        (_) {},
        (value, _, _, _) => text.add(value),
      );
      try {
        await recording.start('/usr/bin/true', model);
        emit(0, 123);
        await recording.pause();
        fail(1);
        await expectLater(recording.resume(), throwsStateError);
        expect(recording.paused, true);
        expect(recording.captures, isEmpty);
        expect(emit(0, 999), 0);
        fail(-1);
        await recording.resume();
        emit(0, 456);
        await recording.pause();
        await recording.stop();
        expect(text, ['marker_123', 'marker_456']);
        expect(recording.captures, isEmpty);
        expect(recording.speeches, isEmpty);
        await expectLater(recording.resume(), throwsStateError);
      } finally {
        fail(-1);
        recording.dispose();
        await recording.closed;
      }
    },
  );

  test(
    'service commands preserve active ownership while paused and reject stale meeting IDs',
    () async {
      final store = Store('${directory.path}/service.db');
      var now = DateTime.utc(2026);
      final domain = Domain(
        store,
        Helper('${directory.path}/unused.sock', '${directory.path}/unused'),
        clock: Clock(() => now),
      );
      final app = Application(domain);
      final id = store.meeting('Pause fixture');
      final note = store.saveNote(null, 'Retained note', 'Private note body');
      store.saveMeetingNotes(id, 'Retained meeting notes');
      store.setPreference('echoCancellation', 'true');
      final epoch = store.workspaceEpoch;
      final recording = Recording(
        library,
        (state) => app.recordingState = state,
        (_, _, _, _) {},
      );
      try {
        await recording.start('/usr/bin/true', model, echoCancellation: true);
        app.recording = recording;
        app.recordingMeeting = id;
        app.recordingBegan = now;
        await expectLater(
          app.call(Operation.meetingsPause.wire, {'id': id + 1}),
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.notFound,
            ),
          ),
        );
        expect(recording.paused, false);
        final paused =
            await app.call(Operation.meetingsPause.wire, {'id': id}) as Map;
        expect(paused['active'], true);
        expect(paused['paused'], true);
        now = now.add(const Duration(seconds: 20));
        expect(app.captureState['elapsed_ms'], paused['elapsed_ms']);
        expect(RemoteRecording(Map<String, dynamic>.from(paused)).paused, true);
        expect(
          RemoteRecording(
            Map<String, dynamic>.from(paused),
          ).echoCancellationState,
          paused['echo_cancellation'],
        );
        expect(
          store.rows('SELECT state FROM meetings WHERE id=?', [
            id,
          ]).single['state'],
          'paused',
        );
        final meetingRows = store.rows('SELECT * FROM meetings WHERE id=?', [
          id,
        ]);
        final meetingNotes = store.meetingNoteRows(id);
        void expectPausedOwnership() {
          expect(store.workspaceEpoch, epoch);
          expect(
            store.rows('SELECT * FROM meetings WHERE id=?', [id]),
            meetingRows,
          );
          expect(store.meetingNoteRows(id), meetingNotes);
          expect(store.noteBody(note), 'Private note body');
          expect(app.recording, same(recording));
          expect(app.recordingMeeting, id);
          expect(app.recordingBegan, DateTime.utc(2026));
          expect(app.captureState['active'], true);
          expect(app.captureState['paused'], true);
          expect(app.captureState['meeting_id'], id);
          expect(recording.captures, isEmpty);
        }

        // Pausing releases the devices, but keeps the recording owner. A new
        // start or workspace clear must not treat it as an idle workspace.
        await expectLater(
          app.call(Operation.meetingsStart.wire, {'id': id}),
          throwsA(
            isA<RpcError>()
                .having((error) => error.code, 'code', RpcErrorCode.busy)
                .having(
                  (error) => error.message,
                  'message',
                  'A meeting is already recording',
                ),
          ),
        );
        expectPausedOwnership();
        await expectLater(
          app.call(Operation.workspaceClear.wire, const {}),
          throwsA(
            isA<RpcError>()
                .having((error) => error.code, 'code', RpcErrorCode.busy)
                .having(
                  (error) => error.message,
                  'message',
                  'Stop recording before clearing the workspace',
                ),
          ),
        );
        expectPausedOwnership();
        expect(recording.echoCancellationState['requested'], true);
        await app.call(Operation.preferencesSet.wire, {
          'key': 'echoCancellation',
          'value': 'false',
        });
        expect(store.preference('echoCancellation'), 'false');
        expect(recording.echoCancellationState['requested'], false);
        expectPausedOwnership();
        if (Platform.isLinux) {
          await expectLater(
            app.call(Operation.preferencesSet.wire, {
              'key': 'echoCancellation',
              'value': 'true',
            }),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'Native echo cancellation is available on macOS',
              ),
            ),
          );
          expect(store.preference('echoCancellation'), 'false');
          expect(recording.echoCancellationState['requested'], false);
          expectPausedOwnership();
        }
        await expectLater(
          app.call(Operation.modelsSpeech.wire, {
            'path': 'unused',
            'runtime': 'unused',
            'digest': 'unused',
          }),
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.busy,
            ),
          ),
        );
        final resumed =
            await app.call(Operation.meetingsResume.wire, {'id': id}) as Map;
        expect(resumed['paused'], false);
        expect(
          store.rows('SELECT state FROM meetings WHERE id=?', [
            id,
          ]).single['state'],
          'recording',
        );
        await app.call(Operation.meetingsPause.wire, const {});
        final stopped =
            await app.call(Operation.meetingsStop.wire, const {}) as Map;
        expect(stopped['active'], false);
        expect(stopped['meeting_id'], isNull);
        expect(stopped['began'], isNull);
        expect(stopped['elapsed_ms'], 0);
        expect(app.captureState['elapsed_ms'], 0);
        expect(stopped['paused'], false);
        expect(
          store.rows('SELECT state FROM meetings WHERE id=?', [
            id,
          ]).single['state'],
          'empty',
        );
        await expectLater(
          app.call(Operation.meetingsResume.wire, const {}),
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.notFound,
            ),
          ),
        );
      } finally {
        await app.close();
        domain.close();
        await domain.helper.close();
        recording.dispose();
        await recording.closed;
        store.close();
      }
    },
  );
}
