import 'dart:ffi';
import 'dart:io';

import 'package:foresight_core/src/model_setup.dart';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String library;
  late void Function(int) mode;
  late void Function() releaseProbe;
  late int Function() probeEntered;
  late int Function() engines, conversations, strings;
  late Store store;
  late File model;
  late Map<String, String> environment;
  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('generation-setup-failure-');
    final source = File('${root.path}/fixture.c')
      ..writeAsStringSync(r'''
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int mode, engines, conversations, strings;
static atomic_int probe_entered, probe_released;
void set_mode(int value) {
  mode = value;
  atomic_store(&probe_entered, 0);
  atomic_store(&probe_released, 0);
}
int has_probe_entered(void) { return atomic_load(&probe_entered); }
void release_probe(void) { atomic_store(&probe_released, 1); }
int engine_count(void) { return engines; }
int conversation_count(void) { return conversations; }
int string_count(void) { return strings; }
void *fs_engine_create(const char *runtime, const char *model) {
  if (mode == 1) return NULL;
  engines++; return malloc(1);
}
void *fs_engine_create_backend(const char *runtime, const char *model, int backend) {
  return fs_engine_create(runtime, model);
}
int fs_engine_probe(void *engine) {
  if (mode == 7) {
    atomic_store(&probe_entered, 1);
    while (!atomic_load(&probe_released)) usleep(1000);
  }
  return mode == 2 || mode == 4 || mode == 5 || mode == 6 ? -7 : 0;
}
char *fs_engine_state(void *engine) {
  if (mode == 4) return NULL;
  strings++;
  return strdup(mode == 5 ? "broken JSON" : mode == 6 ? "{}" : "{\"state\":\"ready\",\"error\":\"corrupt model\"}");
}
int fs_engine_destroy(void *engine) { engines--; free(engine); return 0; }
void *fs_conversation_create(void *engine) {
  if (mode == 3) return NULL;
  conversations++; return malloc(1);
}
int fs_conversation_destroy(void *conversation, int wait) { conversations--; free(conversation); return 0; }
void fs_string_free(char *value) { strings--; free(value); }
''');
    library = '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    final compile = await Process.run('cc', [
      Platform.isMacOS ? '-dynamiclib' : '-shared',
      '-fPIC',
      source.path,
      '-o',
      library,
    ]);
    expect(compile.exitCode, 0, reason: compile.stderr.toString());
    final lib = DynamicLibrary.open(library);
    mode = lib.lookupFunction<Void Function(Int32), void Function(int)>(
      'set_mode',
    );
    probeEntered = lib.lookupFunction<Int32 Function(), int Function()>(
      'has_probe_entered',
    );
    releaseProbe = lib.lookupFunction<Void Function(), void Function()>(
      'release_probe',
    );
    engines = lib.lookupFunction<Int32 Function(), int Function()>(
      'engine_count',
    );
    conversations = lib.lookupFunction<Int32 Function(), int Function()>(
      'conversation_count',
    );
    strings = lib.lookupFunction<Int32 Function(), int Function()>(
      'string_count',
    );
  });
  tearDownAll(() => root.deleteSync(recursive: true));
  setUp(() async {
    environment = Map.of(runtimeConfiguration.environment);
    store = Store('${root.path}/app.db');
    model = File('${root.path}/qwen-model')..writeAsStringSync('fixture');
    await store.register('generation', model.path, '/previous/runtime');
    mode(0);
  });
  tearDown(() {
    runtimeConfiguration.environment
      ..clear()
      ..addAll(environment);
    try {
      expect(engines(), 0);
      expect(conversations(), 0);
      expect(strings(), 0);
    } finally {
      store.close();
      File('${root.path}/app.db').deleteSync();
    }
  });

  for (final failureMode in [1, 2, 3, 4, 5, 6]) {
    test(
      'native setup failure mode $failureMode releases ownership and preserves the prior registration',
      () async {
        final before = Map.of(store.model('generation')!);
        mode(failureMode);
        await expectLater(
          configureGeneration(store, library, model.path, '/candidate/runtime'),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
        expect(store.model('generation'), before);
      },
    );
  }

  test(
    'successful configuration retains exactly one probed engine until its caller closes it',
    () async {
      var registered = false;
      final runtime = await configureGeneration(
        store,
        library,
        model.path,
        '/candidate/runtime',
        onRegister: () => registered = true,
      );
      expect(registered, isTrue);
      expect(runtime.loaded, isTrue);
      expect(runtime.template, 'chatml');
      expect(runtime.effectiveState['state'], 'ready');
      expect(engines(), 1);
      expect(conversations(), 1);
      expect(store.model('generation')!['runtime'], '/candidate/runtime');
      runtime.close();
      runtime.close();
    },
  );

  test(
    'cancellation before and after probe never replaces persistent configuration',
    () async {
      for (final cancelAfterProbe in [false, true]) {
        var checks = 0;
        final before = Map.of(store.model('generation')!);
        await expectLater(
          configureGeneration(
            store,
            library,
            model.path,
            '/candidate/runtime',
            current: () => cancelAfterProbe ? ++checks == 1 : false,
          ),
          throwsStateError,
        );
        expect(store.model('generation'), before);
        expect(engines(), 0);
      }
    },
  );

  test(
    'closing a candidate while its probe is in flight destroys the late engine',
    () async {
      mode(7);
      NativeRuntime? candidate;
      final pending = configureGeneration(
        store,
        library,
        model.path,
        '/candidate/runtime',
        onCandidate: (value) => candidate = value,
      );
      final failed = expectLater(pending, throwsStateError);
      try {
        await eventually(() => probeEntered() == 1);
      } finally {
        try {
          candidate!.close();
        } finally {
          releaseProbe();
          await failed;
        }
      }
      expect(store.model('generation')!['runtime'], '/previous/runtime');
    },
  );

  test(
    'registration failure cleans the candidate and LiteRT uses the bundled runner',
    () async {
      runtimeConfiguration.environment['FORESIGHT_LITERT_RUNNER'] =
          '/owned/bundled-runner';
      final runtime = await configureGeneration(
        store,
        library,
        model.path,
        '/old/runner',
        backend: 'litert_lm',
      );
      expect(runtime.template, 'raw');
      expect(store.model('generation')!['runtime'], '/owned/bundled-runner');
      runtime.close();
      await expectLater(
        configureGeneration(
          store,
          library,
          model.path,
          '/candidate/runtime',
          onRegister: () => throw StateError('registration rejected'),
        ),
        throwsStateError,
      );
      expect(store.model('generation')!['runtime'], '/owned/bundled-runner');
      await expectLater(
        probeNativeModel(
          library,
          '/runner',
          model.path,
          backend: 'unsupported',
        ),
        throwsArgumentError,
      );
      final invalid = NativeRuntime(library);
      await expectLater(
        invalid.load('/runner', model.path, backend: 'unsupported'),
        throwsArgumentError,
      );
      invalid.close();
    },
  );
}
