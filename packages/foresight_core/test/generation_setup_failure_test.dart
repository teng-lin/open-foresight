import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
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
    root = createTestTempDirectorySync('generation-setup-failure-');
    final source = File('${root.path}/fixture.c')
      ..writeAsStringSync(r'''
#include <stdatomic.h>
#include <stdint.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int mode;
static atomic_int engines, conversations, strings;
struct operation { void *resource; pthread_t thread; atomic_int done; int threaded, joined, released; };
struct engine { struct operation *probe; };
static struct operation operations[512];
static uint64_t next_operation = 1, next_owner = 1;
static void *owners[512];
static uint64_t retirements[512];
static uint64_t publish(void *pointer) {
  if (!pointer) return 0;
  const uint64_t owner = next_owner++;
  owners[owner] = pointer;
  return owner;
}
int fs_abi_version(void) { return 1; }
int fs_lifetime_version(void) { return 2; }
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
  engines++; return calloc(1, sizeof(struct engine));
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
static void *run_probe(void *pointer) {
  struct operation *operation = pointer;
  const int result = fs_engine_probe(operation->resource);
  atomic_store(&operation->done, result == 0 ? 1 : 2);
  return NULL;
}
static void *retire_engine(void *pointer) {
  struct operation *operation = pointer;
  struct engine *engine = operation->resource;
  if (engine->probe) pthread_join(engine->probe->thread, NULL);
  fs_engine_destroy(engine);
  atomic_store(&operation->done, 1);
  return NULL;
}
uint64_t fs_engine_probe_async(uint64_t owner) {
  void *pointer = owners[owner];
  uint64_t token = next_operation++;
  struct operation *operation = &operations[token];
  operation->resource = pointer;
  ((struct engine *)pointer)->probe = operation;
  if (pthread_create(&operation->thread, NULL, run_probe, operation)) return 0;
  return token;
}
uint64_t fs_engine_retire(uint64_t owner) {
  if (retirements[owner]) return retirements[owner];
  void *pointer = owners[owner];
  uint64_t token = next_operation++;
  struct operation *operation = &operations[token];
  operation->resource = pointer;
  operation->threaded = 1;
  if (pthread_create(&operation->thread, NULL, retire_engine, operation)) return 0;
  retirements[owner] = token;
  return token;
}
uint64_t fs_conversation_retire(uint64_t owner) {
  if (retirements[owner]) return retirements[owner];
  void *pointer = owners[owner];
  uint64_t token = next_operation++;
  fs_conversation_destroy(pointer, 1);
  atomic_store(&operations[token].done, 1);
  retirements[owner] = token;
  return token;
}
uint64_t fs_speech_retire(uint64_t owner) { return 0; }
uint64_t fs_speech_join_async(uint64_t owner) { return 0; }
uint64_t fs_capture_finish_async(uint64_t owner) { return 0; }
uint64_t fs_capture_retire(uint64_t owner) { return 0; }
int fs_operation_status(uint64_t token) {
  if (token == 0 || token >= next_operation || operations[token].released) return -1;
  return atomic_load(&operations[token].done);
}
int fs_operation_release(uint64_t token) {
  if (fs_operation_status(token) <= 0) return -1;
  struct operation *operation = &operations[token];
  if (operation->threaded && !operation->joined) {
    pthread_join(operation->thread, NULL);
    operation->joined = 1;
  }
  operation->released = 1;
  return 0;
}


uint64_t fs_owned_engine_create(const char *runtime,const char *model,int backend,int type) {
  return publish(fs_engine_create_backend(runtime,model,backend));
}
uint64_t fs_owned_conversation_create(uint64_t owner) {
  return publish(fs_conversation_create(owners[owner]));
}
char *fs_owned_engine_state(uint64_t owner) { return fs_engine_state(owners[owner]); }
uint64_t fs_owned_speech_create(const char *runtime,const char *model) { return 0; }
uint64_t fs_owned_capture_start(const char *target,int channel,int rate,int echo) { return 0; }
char *fs_owned_event_poll(uint64_t owner,int timeout) { return NULL; }
int fs_owned_generate_options(uint64_t owner,const char*id,const char*prompt,const char*schema,int limit){return -1;}
int fs_owned_generate_tools(uint64_t owner,const char*id,const char*prompt,const char*tools,int limit){return -1;}
int fs_owned_generation_tool_reply(uint64_t owner,const char*id,const char*message){return -1;}
int fs_owned_generation_cancel(uint64_t owner){return -1;}
int fs_owned_speech_push(uint64_t owner,const int16_t*samples,size_t count,int rate){return -1;}
int fs_owned_speech_finish(uint64_t owner,const char*id){return -1;}
int fs_owned_speech_cancel(uint64_t owner){return -1;}
int fs_owned_capture_set_echo_cancellation(uint64_t owner,int enabled){return -1;}
int fs_owner_release(uint64_t owner) {
  if (!retirements[owner] || fs_operation_release(retirements[owner])) return -1;
  owners[owner] = NULL;
  retirements[owner] = 0;
  return 0;
}
''');
    library = '${root.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    final compile = await Process.run('cc', [
      Platform.isMacOS ? '-dynamiclib' : '-shared',
      '-fPIC',
      '-pthread',
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
  setUpAll(() {
    addTearDown(() => root.deleteSync(recursive: true));
  });
  setUp(() async {
    environment = Map.of(runtimeConfiguration.environment);
    store = Store('${root.path}/app.db');
    model = File('${root.path}/qwen-model')..writeAsStringSync('fixture');
    await store.register('generation', model.path, '/previous/runtime');
    mode(0);
  });
  setUp(() {
    addTearDown(() {
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
    'models.generation defaults to litert_lm and explicit llama_cpp remains available',
    () async {
      runtimeConfiguration.environment['FORESIGHT_NATIVE'] = library;
      final helper = Helper(
        '${root.path}/unused.sock',
        '${root.path}/helper',
        manageProcess: false,
      );
      final domain = Domain(store, helper);
      final app = Application(domain);
      try {
        await app.call('models.generation', {
          'path': model.path,
          'runtime': '/candidate/runtime',
        });
        expect(store.model('generation')!['backend'], 'litert_lm');
        await app.call('models.generation', {
          'path': model.path,
          'runtime': '/candidate/runtime',
          'backend': 'llama_cpp',
        });
        expect(store.model('generation')!['backend'], 'llama_cpp');
      } finally {
        await app.close();
        domain.close();
        await domain.drain();
        await helper.close();
      }
    },
  );

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
      expect(runtime.template, 'raw');
      expect(runtime.effectiveState['state'], 'ready');
      expect(engines(), 1);
      expect(conversations(), 1);
      expect(store.model('generation')!['runtime'], '/candidate/runtime');
      runtime.close();
      await runtime.closed;
      runtime.close();
      await runtime.closed;
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
          throwsA(
            isA<RpcError>()
                .having((e) => e.code, 'code', RpcErrorCode.cancelled)
                .having((e) => e.message, 'message', 'Model setup cancelled'),
          ),
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
      final failed = expectLater(
        pending,
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.cancelled,
          ),
        ),
      );
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
      await runtime.closed;
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
      await invalid.closed;
    },
  );
}
