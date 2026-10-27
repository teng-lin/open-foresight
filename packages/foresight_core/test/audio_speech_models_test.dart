import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/application_services/audio_recognition_scheduler.dart';
import 'package:foresight_core/src/application_services/audio_speech_models.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/read_models.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

final class CacheOwner implements AudioSpeechCacheOwner {
  int closes = 0;
  Object? failure;
  Completer<void>? fence;
  @override
  Future<void> close() async {
    closes++;
    await fence?.future;
    if (failure case final error?) throw error;
  }
}

void main() {
  late Directory root;
  late File model;
  late ModelRegistration? registration;
  late AudioSpeechModels models;
  late CacheOwner owner;
  int creations = 0;
  String getDigest() =>
      sha256.convert(utf8.encode('verified weights')).toString();
  ModelRegistration registered({String runtime = '/runtime'}) =>
      ModelRegistration.fromRow({
        'kind': 'speech',
        'path': model.path,
        'digest': getDigest(),
        'runtime': runtime,
        'backend': '',
        'model_type': 0,
      });

  setUp(() {
    root = createTestTempDirectorySync('saved-speech-models-');
    model = File('${root.path}/weights')..writeAsStringSync('verified weights');
    registration = registered();
    owner = CacheOwner();
    creations = 0;
    models = AudioSpeechModels(
      registration: () => registration,
      createCache: (runtime, path, current) async {
        expect(current(), isTrue);
        expect(path, model.resolveSymbolicLinksSync());
        creations++;
        return owner;
      },
    );
  });

  test(
    'concurrent leases share verified keeper across job boundaries',
    () async {
      final leases = await Future.wait([
        models.acquire(getDigest(), () => true),
        models.acquire(getDigest(), () => true),
      ]);
      expect(creations, 1);
      expect(models.activeLeases, 2);
      await leases.first.release();
      await leases.first.release();
      expect(models.activeLeases, 1);
      await leases.last.release();
      final next = await models.acquire(getDigest(), () => true);
      expect(creations, 1);
      expect(owner.closes, 0);
      await next.release();
      await models.close();
      expect(owner.closes, 1);
    },
  );

  test(
    'replacement waits actual reader release then cache retirement',
    () async {
      final lease = await models.acquire(getDigest(), () => true);
      final fence = owner.fence = Completer<void>();
      var done = false;
      final suspended = models.suspend().then((_) => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(models.suspended, isTrue);
      expect(owner.closes, 0);
      expect(done, isFalse);
      await expectLater(
        models.acquire(getDigest(), () => true),
        throwsA(anything),
      );
      await lease.release();
      await Future<void>.delayed(Duration.zero);
      expect(owner.closes, 1);
      expect(done, isFalse);
      expect(models.resume, throwsStateError);
      fence.complete();
      await suspended;
      models.resume();
      owner = CacheOwner();
      final second = await models.acquire(getDigest(), () => true);
      expect(creations, 2);
      await second.release();
      await models.close();
    },
  );

  test('changed bytes never admit a native keeper', () async {
    model.writeAsStringSync('tampered weights');
    await expectLater(
      models.acquire(getDigest(), () => true),
      throwsA(
        isA<AudioRecognitionBlocked>().having(
          (error) => error.reason,
          'reason',
          'frozen_model_unavailable',
        ),
      ),
    );
    expect(creations, 0);
    await models.close();
  });

  test(
    'missing and wrong revision remain blocked without switching model',
    () async {
      await expectLater(
        models.acquire('other', () => true),
        throwsA(isA<AudioRecognitionBlocked>()),
      );
      model.deleteSync();
      await expectLater(
        models.acquire(getDigest(), () => true),
        throwsA(isA<AudioRecognitionBlocked>()),
      );
      expect(creations, 0);
      registration = null;
      await expectLater(
        models.acquire(getDigest(), () => true),
        throwsA(isA<AudioRecognitionBlocked>()),
      );
      await models.close();
    },
  );

  test(
    'runtime replacement needs explicit barrier even for identical weights',
    () async {
      final first = await models.acquire(getDigest(), () => true);
      registration = registered(runtime: '/other-runtime');
      await expectLater(
        models.acquire(getDigest(), () => true),
        throwsA(
          isA<AudioRecognitionBlocked>().having(
            (error) => error.reason,
            'reason',
            'speech_configuration_needs_barrier',
          ),
        ),
      );
      await first.release();
      await models.suspend();
      models.resume();
      final next = await models.acquire(getDigest(), () => true);
      expect(next.runtime, '/other-runtime');
      expect(creations, 2);
      await next.release();
      await models.close();
    },
  );

  test(
    'suspend during native admission retires candidate before completing',
    () async {
      final admitted = Completer<void>(), gate = Completer<void>();
      models = AudioSpeechModels(
        registration: () => registration,
        createCache: (runtime, path, current) async {
          admitted.complete();
          await gate.future;
          return owner;
        },
      );
      final acquisition = models.acquire(getDigest(), () => true);
      final rejected = expectLater(acquisition, throwsA(anything));
      await admitted.future;
      final suspended = models.suspend();
      gate.complete();
      await rejected;
      await suspended;
      expect(owner.closes, 1);
      expect(models.activeLeases, 0);
      models.resume();
      await models.close();
    },
  );

  test('unconfirmed retirement prevents reopening and replacement', () async {
    final lease = await models.acquire(getDigest(), () => true);
    await lease.release();
    owner.failure = StateError('unconfirmed native exit');
    await expectLater(models.suspend(), throwsStateError);
    expect(models.restartRequired, isTrue);
    expect(models.resume, throwsStateError);
    await expectLater(
      models.acquire(getDigest(), () => true),
      throwsA(anything),
    );
    expect(creations, 1);
  });

  test('cancelled caller cannot receive a live lease', () async {
    await expectLater(
      models.acquire(getDigest(), () => false),
      throwsA(anything),
    );
    expect(creations, 0);
    expect(models.activeLeases, 0);
    await models.close();
    expect(models.resume, throwsStateError);
  });

  final native = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  test(
    'native keeper creates and acknowledges retirement without devices',
    () async {
      models = AudioSpeechModels.native(
        registration: () => registration,
        bindings: NativeLibrary(DynamicLibrary.open(native!)),
      );
      final first = await models.acquire(getDigest(), () => true);
      final second = await models.acquire(getDigest(), () => true);
      await first.release();
      await second.release();
      await models.close();
      expect(models.restartRequired, isFalse);
    },
    skip: native == null
        ? 'Requires native library; no model inference'
        : false,
  );
}
