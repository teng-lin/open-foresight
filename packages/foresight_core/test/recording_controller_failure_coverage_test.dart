import 'sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory root, profile;
  late String library;
  late DynamicLibrary fixture;
  late Store store;
  late Helper helper;
  late AdapterDomain domain;
  late Application app;
  late Map<String, String> environment;
  late int meeting;

  void failChannel(int value) =>
      fixture.lookupFunction<Void Function(Int32), void Function(int)>(
        'fixture_fail_channel',
      )(value);
  int emit(Map<String, Object> value) {
    final pointer = jsonEncode(value).toNativeUtf8();
    try {
      return fixture.lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>)
      >('fixture_emit')(0, pointer);
    } finally {
      calloc.free(pointer);
    }
  }

  void pcm(int marker, int count) {
    final bytes = ByteData(count * 2);
    for (var i = 0; i < count; i++) {
      bytes.setInt16(i * 2, marker, Endian.little);
    }
    expect(
      emit({
        'type': 'pcm',
        'sampleRate': 1000,
        'volume': .02,
        'data': base64Encode(bytes.buffer.asUint8List()),
      }),
      1,
    );
    app.recording!.drain();
  }

  setUpAll(() async {
    root = createTestTempDirectorySync('recording-controller-errors-');
    library = '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    await buildCachedNativeFixture(
      source: 'test/fixtures/recording_native_stub.cpp',
      output: library,
    );
    fixture = DynamicLibrary.open(library);
    addTearDown(() => root.deleteSync(recursive: true));
  });
  setUp(() async {
    profile = Directory('${root.path}/profile')..createSync();
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment['FORESIGHT_NATIVE'] = library;
    store = Store('${profile.path}/app.db');
    helper = Helper(
      '${profile.path}/unused.sock',
      '${profile.path}/unused',
      manageProcess: false,
    );
    domain = AdapterDomain(store, helper);
    app = Application(domain);
    meeting = store.meeting('Controlled capture');
    failChannel(-1);
    addTearDown(() async {
      failChannel(-1);
      await app.close();
      domain.close();
      await helper.close();
      store.close();
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
      profile.deleteSync(recursive: true);
    });
  });

  Future<void> speechModel() async {
    final model = File('${profile.path}/speech-fixture')
      ..writeAsStringSync('ABI fixture only');
    await store.register('speech', model.path, '/usr/bin/true');
  }

  String meetingState() =>
      store.rows('SELECT state FROM meetings WHERE id=?', [
            meeting,
          ]).single['state']
          as String;

  test(
    'capture startup refusal releases the first channel and leaves meeting retryable',
    () async {
      await expectLater(
        app.startRecording(meeting),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.unavailable,
          ),
        ),
      );
      await speechModel();
      final prior = meetingState();
      failChannel(1);
      await expectLater(app.startRecording(meeting), throwsStateError);
      expect(emit({'type': 'state', 'state': 'must not be delivered'}), 0);
      expect(app.recording, isNull);
      expect(app.captureState['active'], isFalse);
      expect(meetingState(), prior);
      failChannel(-1);
      await app.startRecording(meeting);
      expect(app.captureState['active'], isTrue);
      await app.stopRecording();
      expect(app.recording, isNull);
    },
  );

  test(
    'capture gaps persist a recoverable interruption alongside committed speech',
    () async {
      await speechModel();
      await app.startRecording(meeting);
      pcm(211, 5000);
      await eventually(() => app.provisionalTranscript.isNotEmpty);
      pcm(211, 20000);
      await eventually(
        () => store.rows('SELECT * FROM transcript WHERE final=1').isNotEmpty,
      );
      expect(app.provisionalTranscript.values, everyElement(isEmpty));
      expect(
        emit({
          'type': 'gap',
          'reason': 'capture_buffer_overflow',
          'discarded_bytes': 64,
        }),
        1,
      );
      app.recording!.drain();
      expect(meetingState(), 'interrupted');
      final interruption = store
          .rows('SELECT * FROM transcript WHERE final=0')
          .single;
      expect(interruption['text'], contains('capture_buffer_overflow'));
      expect(interruption['text'], contains('64 residual bytes discarded'));
      await app.stopRecording();
      expect(meetingState(), 'completed');
      expect(
        store.rows('SELECT * FROM transcript WHERE final=1').single['text'],
        'marker_211',
      );
      expect(app.captureState['active'], isFalse);
      expect(app.provisionalTranscript, isEmpty);
      await app.indexMeeting(meeting);
      expect(domain.indexed, isNotEmpty);
    },
  );

  test('inactivity finalizes capture and releases its owned devices', () async {
    await speechModel();
    store.setPreference('inactivity', '0.001');
    await app.startRecording(meeting);
    await eventually(
      () => app.recording == null,
      timeout: const Duration(seconds: 8),
    );
    expect(emit({'type': 'state', 'state': 'late'}), 0);
    expect(meetingState(), 'empty');
    expect(app.captureState['active'], isFalse);
  });

  test(
    'capture failure retains committed text and publishes interrupted state',
    () async {
      await speechModel();
      await app.startRecording(meeting);
      pcm(319, 20000);
      await eventually(
        () => store.rows('SELECT * FROM transcript WHERE final=1').isNotEmpty,
      );
      expect(
        emit({'type': 'error', 'message': 'fixture route disappeared'}),
        1,
      );
      app.recording!.drain();
      await app.stopRecording();
      expect(
        app.recordingState,
        contains('Transcript retained after speech failure'),
      );
      expect(app.recordingState, contains('fixture route disappeared'));
      expect(meetingState(), 'interrupted');
      expect(
        store.rows('SELECT * FROM transcript WHERE final=1').single['text'],
        'marker_319',
      );
      expect(app.recording, isNull);
      expect(app.recordingMeeting, isNull);
      expect(emit({'type': 'state', 'state': 'late'}), 0);
    },
  );
}
