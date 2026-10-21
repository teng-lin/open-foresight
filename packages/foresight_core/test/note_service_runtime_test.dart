import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/application.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

class FixtureRuntime extends NativeRuntime {
  FixtureRuntime({this.readyAfterLoad = true, this.loadGate, this.loadFailure})
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');

  final bool readyAfterLoad;
  final Completer<void>? loadGate;
  final Object? loadFailure;
  final loadStarted = Completer<void>();
  bool _ready = false;
  int loads = 0;
  int closes = 0;
  int conversations = 0;
  String? loadedRuntime;
  String? loadedModel;
  String? loadedBackend;

  @override
  bool get loaded => _ready;

  @override
  Map<String, dynamic> get effectiveState => {
    'state': _ready ? 'ready' : 'unconfigured',
    'tools': true,
  };

  @override
  Future<void> load(
    String runtime,
    String model, {
    String backend = 'llama_cpp',
  }) async {
    loads++;
    loadedRuntime = runtime;
    loadedModel = model;
    loadedBackend = backend;
    loadStarted.complete();
    if (loadFailure case final failure?) throw failure;
    if (loadGate case final gate?) await gate.future;
    _ready = readyAfterLoad;
  }

  @override
  void close() {
    closes++;
    _ready = false;
  }

  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async* {
    conversations++;
    yield {'type': 'delta', 'text': '- Enhanced note'};
    yield {'type': 'done', 'status': 'completed'};
  }
}

class FixtureDomain extends Domain {
  FixtureDomain(super.store, super.helper);
  final candidates = <FixtureRuntime>[];
  int created = 0;
  int acquisitions = 0;
  int resets = 0;

  @override
  NativeRuntime createNoteEnhancementRuntime() => candidates[created++];

  @override
  Future<NativeRuntime?> noteEnhancementService() {
    acquisitions++;
    return super.noteEnhancementService();
  }

  @override
  Future<void> resetNoteEnhancementService() async {
    resets++;
    await super.resetNoteEnhancementService();
  }
}

void main() {
  late Application app;
  late Directory directory;
  late Store store;
  late Helper helper;
  late FixtureDomain domain;

  void registerModel() {
    store.db.execute(
      "INSERT INTO models(kind,path,digest,runtime,backend) VALUES('generation','/fixture/model.litertlm','fixture','/fixture/runner','litert_lm')",
    );
  }

  int seedNote() {
    store.setPreference('liveEnhance', 'false');
    final id = store.meeting('Meeting');
    store.saveMeetingNotes(id, 'Raw note');
    store.transcript(id, 'Transcript evidence', true, 0, 20, 'imported');
    return id;
  }

  setUp(() {
    directory = createTestTempDirectorySync('note-service-');
    store = Store('${directory.path}/app.db');
    helper = Helper('${directory.path}/sock', '${directory.path}/helper');
    domain = FixtureDomain(store, helper);
    app = Application(domain);
  });

  setUp(() {
    addTearDown(() async {
      await app.close();
      domain.close();
      domain.generator?.close();
      await helper.close();
      store.close();
      directory.deleteSync(recursive: true);
    });
  });

  test(
    'missing registration returns null without constructing a runtime',
    () async {
      expect(await domain.noteEnhancementService(), isNull);
      expect(domain.created, 0);
    },
  );

  test(
    'concurrent getters share one owned candidate and one pending load',
    () async {
      registerModel();
      final gate = Completer<void>();
      final runtime = FixtureRuntime(loadGate: gate);
      domain.candidates.add(runtime);
      final first = domain.noteEnhancementService();
      final second = domain.noteEnhancementService();
      await runtime.loadStarted.future;
      expect(domain.generator, same(runtime));
      expect(domain.created, 1);
      expect(runtime.loads, 1);
      gate.complete();
      expect(await first, same(runtime));
      expect(await second, same(runtime));
      expect(await domain.noteEnhancementService(), same(runtime));
      expect(domain.created, 1);
      expect(runtime.loadedRuntime, '/fixture/runner');
      expect(runtime.loadedModel, '/fixture/model.litertlm');
      expect(runtime.loadedBackend, 'litert_lm');
    },
  );

  test(
    'reset closes previous owned runtime and next getter loads a new candidate',
    () async {
      registerModel();
      final first = FixtureRuntime();
      final second = FixtureRuntime();
      domain.candidates.addAll([first, second]);
      expect(await domain.noteEnhancementService(), same(first));
      await domain.resetNoteEnhancementService();
      expect(first.closes, 1);
      expect(domain.generator, isNull);
      expect(await domain.noteEnhancementService(), same(second));
      expect(second.loads, 1);
      expect(domain.created, 2);
    },
  );

  test(
    'failed load propagates and a later request retries with a new candidate',
    () async {
      registerModel();
      final failure = StateError('fixture load failed');
      final first = FixtureRuntime(loadFailure: failure);
      final second = FixtureRuntime();
      domain.candidates.addAll([first, second]);
      await expectLater(
        domain.noteEnhancementService(),
        throwsA(same(failure)),
      );
      expect(await domain.noteEnhancementService(), same(second));
      expect(first.closes, 1);
      expect(first.loads, 1);
      expect(second.loads, 1);
    },
  );

  test(
    'domain closure during load rejects and closes the obsolete candidate',
    () async {
      registerModel();
      final gate = Completer<void>();
      final runtime = FixtureRuntime(loadGate: gate);
      domain.candidates.add(runtime);
      final pending = domain.noteEnhancementService();
      await runtime.loadStarted.future;
      domain.close();
      final rejected = expectLater(
        pending,
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.cancelled,
          ),
        ),
      );
      gate.complete();
      await rejected;
      expect(runtime.closes, greaterThanOrEqualTo(1));
      expect(runtime.loaded, isFalse);
    },
  );

  test(
    'Application resets an unready loaded candidate and generates with replacement',
    () async {
      registerModel();
      final id = seedNote();
      final first = FixtureRuntime(readyAfterLoad: false);
      final second = FixtureRuntime();
      domain.candidates.addAll([first, second]);
      await app.enhanceNotes(id);
      expect(domain.acquisitions, 2);
      expect(domain.resets, 1);
      expect(domain.created, 2);
      expect(first.closes, 1);
      expect(second.conversations, 1);
      expect(store.meetingEnhancedNotes(id), '- Enhanced note');
    },
  );

  test(
    'Application reports missing download after exactly two null acquisitions',
    () async {
      final id = seedNote();
      await expectLater(
        app.enhanceNotes(id),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains(
              'LiteRT-LM service is not ready: on-device inference model is not downloaded. Please check Settings -> Model Management.',
            ),
          ),
        ),
      );
      expect(domain.acquisitions, 2);
      expect(domain.resets, 1);
      expect(domain.created, 0);
      expect(store.meetingEnhancedNotes(id), isEmpty);
    },
  );

  test(
    'Application reports installed model unready without a third acquisition',
    () async {
      registerModel();
      final id = seedNote();
      domain.candidates.addAll([
        FixtureRuntime(readyAfterLoad: false),
        FixtureRuntime(readyAfterLoad: false),
      ]);
      await expectLater(
        app.enhanceNotes(id),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains(
              'LiteRT-LM service is not ready. Please try again in a moment.',
            ),
          ),
        ),
      );
      expect(domain.acquisitions, 2);
      expect(domain.resets, 1);
      expect(domain.created, 2);
    },
  );
}
