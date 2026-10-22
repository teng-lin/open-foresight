import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/application_services/model_registry.dart';
import 'package:foresight_core/src/dedicated_query_runtime.dart';
import 'package:foresight_core/src/dedicated_query_acquisition.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/operation_requests.dart';
import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class _OwnedQueryRuntime implements QueryCompletionRuntime {
  final requests = <String>[];
  final cancelled = <String>[];
  var closes = 0;

  @override
  Future<String> complete(String prompt, String requestId) async {
    requests.add(requestId);
    return 'Who owns launch?';
  }

  @override
  void cancel(String requestId) => cancelled.add(requestId);

  @override
  Future<void> close() async => closes++;
}

void main() {
  late Directory root;
  late Store store;
  late Helper helper;
  late Domain domain;
  late ModelRegistry registry;
  var wakes = 0;

  setUp(() {
    root = createTestTempDirectorySync('model-registry-errors-');
    store = Store('${root.path}/app.db');
    helper = Helper('${root.path}/unused.sock', '${root.path}/unused');
    domain = Domain(store, helper);
    wakes = 0;
    registry = ModelRegistry(
      domain: domain,
      changed: () {},
      ownsDetection: (_) => true,
      wakeDetection: () => wakes++,
      invalidateEmbeddings: () {},
    );
    addTearDown(() async {
      await registry.close();
      domain.close();
      await helper.close();
      store.close();
      root.deleteSync(recursive: true);
    });
  });

  ModelsRegisterRequest registration(Map<String, dynamic> args) =>
      ModelsRegisterRequest.decode(
        OperationRequestContext.decode(Operation.modelsRegister, args),
      );

  test(
    'portable registration wakes detection and a retired backend closes it',
    () async {
      await expectLater(
        registry.detectQuestions('context', 'before'),
        throwsStateError,
      );
      final model = File('${root.path}/model')
        ..writeAsStringSync('owned fixture');
      final worker = File('${root.path}/worker')
        ..writeAsStringSync('''#!/usr/bin/env python3
import json,sys
print(json.dumps({'type':'ready'}),flush=True)
for line in sys.stdin:
 request=json.loads(line)
 print(json.dumps({'type':'result','id':request['id'],'text':'Who owns launch?什么时候发布？'}),flush=True)
''');
      expect(
        (await Process.run('/bin/chmod', ['700', worker.path])).exitCode,
        0,
      );
      final args = {
        'kind': dedicatedQueryModelKind,
        'path': model.path,
        'runtime': worker.path,
        'digest': sha256.convert(model.readAsBytesSync()).toString(),
        'backend': portableQueryBackend,
      };
      await registry.register(registration(args));
      expect(wakes, 1);
      expect(
        store.model(dedicatedQueryModelKind)!['path'],
        model.absolute.path,
      );
      expect(
        await registry.detectQuestions('context', 'current'),
        unorderedEquals(['Who owns launch?', '什么时候发布？']),
      );
      store.setPreference('queryOutputPolicy', 'legacy-ascii');
      expect(await registry.detectQuestions('context', 'ascii'), [
        'Who owns launch?',
      ]);
      store.db.execute('UPDATE models SET backend=? WHERE kind=?', [
        'retired',
        dedicatedQueryModelKind,
      ]);
      await expectLater(
        registry.detectQuestions('context', 'retired'),
        throwsStateError,
      );
      expect(
        wakes,
        1,
        reason: 'A rejected detector must not schedule new work',
      );
    },
  );

  test(
    'cancelled and unsupported registration preserve the previous model',
    () async {
      final model = File('${root.path}/prior')..writeAsStringSync('previous');
      await store.register(
        dedicatedQueryModelKind,
        model.path,
        '/bin/true',
        backend: 'legacy_query_cpu',
      );
      final previous = Map.of(store.model(dedicatedQueryModelKind)!);
      await expectLater(
        registry.register(
          registration({
            'kind': dedicatedQueryModelKind,
            'path': model.path,
            'backend': 'unsupported',
          }),
        ),
        throwsStateError,
      );
      final worker = File('${root.path}/must-not-run')
        ..writeAsStringSync('#!/bin/sh\nexit 99\n');
      expect(
        (await Process.run('/bin/chmod', ['700', worker.path])).exitCode,
        0,
      );
      await expectLater(
        registry.register(
          registration({
            'kind': dedicatedQueryModelKind,
            'path': model.path,
            'runtime': worker.path,
            'digest': sha256.convert(model.readAsBytesSync()).toString(),
            'backend': portableQueryBackend,
          }),
          current: () => false,
        ),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      expect(store.model(dedicatedQueryModelKind), previous);
      expect(wakes, 0);
    },
  );

  test(
    'lost detection ownership never calls the provided worker and close joins once',
    () async {
      await registry.close();
      final runtime = _OwnedQueryRuntime();
      var owns = false;
      registry = ModelRegistry(
        domain: domain,
        changed: () {},
        ownsDetection: (_) => owns,
        wakeDetection: () {},
        invalidateEmbeddings: () {},
        queryRuntime: runtime,
      );
      await expectLater(
        registry.detectQuestions('text', 'stale'),
        throwsA(isA<RpcError>()),
      );
      expect(runtime.requests, isEmpty);
      owns = true;
      expect(await registry.detectQuestions('text', 'owned'), [
        'Who owns launch?',
      ]);
      registry.cancelDetection('owned');
      expect(runtime.cancelled, ['owned']);
      final close = registry.close();
      expect(identical(close, registry.close()), isTrue);
      await close;
      await expectLater(
        registry.detectQuestions('text', 'closed'),
        throwsA(isA<RpcError>()),
      );
      expect(runtime.requests, ['owned']);
      expect(runtime.closes, 1);
    },
  );

  test(
    'speech cancellation maps to cancelled without registering a model',
    () async {
      final request = ModelsSpeechRequest.decode(
        OperationRequestContext.decode(Operation.modelsSpeech, {
          'path': '${root.path}/unopened-model',
          'runtime': Platform.resolvedExecutable,
          'digest': '0' * 64,
        }),
      );
      await expectLater(
        registry.configureSpeechModel(request, current: () => false),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      expect(store.model('speech'), isNull);
    },
  );

  test(
    'model terms deny acquisition before platform or network access',
    () async {
      final environment = Map.of(runtimeConfiguration.environment);
      addTearDown(
        () => runtimeConfiguration.environment
          ..clear()
          ..addAll(environment),
      );
      runtimeConfiguration.environment['FORESIGHT_QUERY_TERMS_URL'] =
          'https://fixture.invalid/terms';
      await expectLater(
        registry.acquireQuery(),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.denied,
          ),
        ),
      );
      expect(registry.acquiring, isFalse);
      expect(registry.acquisitionState['received'], 0);
      if (!Platform.isMacOS) {
        store.setPreference(dedicatedQueryTermsKey, 'accepted');
        await expectLater(
          registry.acquireQuery(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'reason',
              contains('requires macOS'),
            ),
          ),
        );
        expect(registry.acquiring, isFalse);
      }
      expect(store.model(dedicatedQueryModelKind), isNull);
    },
  );
}
