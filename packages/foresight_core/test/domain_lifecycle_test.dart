import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:grpc/grpc.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/store.dart';

import 'package:foresight_test_support/delayed_index_service.dart';

class DiscoveredRuntime extends NativeRuntime {
  DiscoveredRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  int closes = 0;
  @override
  void close() => closes++;
}

void main() {
  for (final hasCandidate in [false, true]) {
    test(
      'resume refuses late discovery after close, candidate=$hasCandidate',
      () async {
        final temporary = createTestTempDirectorySync('resume-discovery-');
        final store = Store('${temporary.path}/app.db');
        final helper = Helper(
          '${temporary.path}/helper.sock',
          '${temporary.path}/helper',
          manageProcess: false,
        );
        final entered = Completer<void>();
        final release = Completer<NativeRuntime?>();
        bool Function()? stillCurrent;
        final candidate = hasCandidate ? DiscoveredRuntime() : null;
        final domain = Domain(
          store,
          helper,
          discoverGeneration:
              (receivedStore, library, {current, onCandidate, retire}) {
                expect(receivedStore, same(store));
                stillCurrent = current;
                entered.complete();
                return release.future;
              },
        );
        try {
          final pending = domain.resume();
          final cancelled = expectLater(
            pending,
            throwsA(
              isA<RpcError>().having(
                (error) => error.code,
                'code',
                RpcErrorCode.cancelled,
              ),
            ),
          );
          await entered.future;
          expect(stillCurrent!(), isTrue);
          domain.close();
          expect(stillCurrent!(), isFalse);
          // Keep this negative control safe: a late fallback read must not even
          // inspect a retired Store whose schema is no longer supported.
          store.db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
          release.complete(candidate);
          await cancelled;
          expect(domain.generator, isNull);
          expect(candidate?.closes, hasCandidate ? 1 : null);
          expect(domain.resumeInProgress, isFalse);
        } finally {
          if (!release.isCompleted) release.complete(candidate);
          domain.close();
          await helper.close();
          store.close();
        }
      },
    );
  }

  test('resume adopts discovery only while its owner remains open', () async {
    final temporary = createTestTempDirectorySync('resume-current-');
    final store = Store('${temporary.path}/app.db');
    final helper = Helper(
      '${temporary.path}/helper.sock',
      '${temporary.path}/helper',
      manageProcess: false,
    );
    final entered = Completer<void>();
    final release = Completer<NativeRuntime?>();
    final candidate = DiscoveredRuntime();
    final domain = Domain(
      store,
      helper,
      discoverGeneration: (_, _, {current, onCandidate, retire}) {
        expect(current!(), isTrue);
        entered.complete();
        return release.future;
      },
    );
    try {
      final pending = domain.resume();
      await entered.future;
      expect(domain.generator, isNull);
      release.complete(candidate);
      await pending;
      expect(domain.generator, same(candidate));
      expect(candidate.closes, 0);
      expect(domain.resumeInProgress, isFalse);
    } finally {
      if (!release.isCompleted) release.complete(candidate);
      domain.close();
      candidate.close();
      await helper.close();
      store.close();
    }
  });

  test('late empty discovery never enters a disposed SQLite handle', () async {
    final temporary = createTestTempDirectorySync('resume-disposed-');
    final result = await Process.run(Platform.resolvedExecutable, [
      'test/fixtures/resume_discovery_after_close.dart',
      temporary.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('cancelled-before-closed-store-read'));
  });

  test('embedding backend selection survives app database restart', () async {
    final temporary = createTestTempDirectorySync('foresight-gpu-restore-');
    addTearDown(() {
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    });
    final model = File('${temporary.path}/model.litertlm')
      ..writeAsStringSync('registration fixture');
    final service = DelayedIndexService();
    final server = Server.create(services: [service]);
    final socket = '${temporary.path}/helper.sock';
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    final helper = Helper(socket, '${temporary.path}/helper');
    var store = Store('${temporary.path}/app.db');
    try {
      for (final backend in [
        'litert_lm_embedding_gpu',
        'litert_lm_embedding_cpu',
      ]) {
        await store.register('embedding', model.path, '', backend: backend);
        store.close();
        store = Store('${temporary.path}/app.db');
        final domain = Domain(store, helper);
        await domain.resume();
        final request = service.configurations.last;
        expect(request.embeddingModelPath, model.absolute.path);
        expect(request.hasUseGpu(), true);
        expect(request.useGpu, backend == 'litert_lm_embedding_gpu');
        domain.close();
      }
      await expectLater(
        store.register(
          'generation',
          model.path,
          '',
          backend: 'litert_lm_embedding_gpu',
        ),
        throwsArgumentError,
      );
      expect(service.configurations.length, 2);
    } finally {
      store.close();
      await helper.close();
      await server.shutdown();
      temporary.deleteSync(recursive: true);
    }
  });

  test(
    'pause retains queued indexing while allowing deletion and shutdown',
    () async {
      final temporary = createTestTempDirectorySync('foresight-source-pause-');
      addTearDown(() {
        if (temporary.existsSync()) temporary.deleteSync(recursive: true);
      });
      final service = DelayedIndexService();
      final server = Server.create(services: [service]);
      final socket = '${temporary.path}/helper.sock';
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final helper = Helper(socket, '${temporary.path}/helper');
      final store = Store('${temporary.path}/app.db');
      final domain = Domain(store, helper);
      String source(String title) =>
          store.importText(title, 'Source content.', 'text/plain', 'fixture');
      final active = source('Active'),
          queued = source('Queued'),
          later = source('Later');
      var storeClosed = false;
      try {
        final first = domain.index(active);
        await service.started.future.timeout(const Duration(seconds: 5));
        final second = domain.index(queued);
        domain.pauseSources();
        domain.pauseSources();
        service.release.complete();
        await first;
        expect(
          store.sources.singleWhere((s) => s['id'] == active)['state'],
          'indexed',
        );
        // This would deadlock if a paused index held the mutation queue.
        await domain.delete(queued).timeout(const Duration(seconds: 5));
        expect(service.calls, 1);
        domain.resumeSources();
        domain.resumeSources();
        await second;
        expect(
          service.calls,
          1,
          reason: 'Deleted queued source must not be indexed',
        );
        domain.pauseSources();
        final third = domain.index(later);
        expect(service.calls, 1);
        domain.resumeSources();
        await third;
        expect(service.calls, 2);
        expect(
          store.sources.singleWhere((s) => s['id'] == later)['state'],
          'indexed',
        );
        domain.pauseSources();
        final waiting = expectLater(
          domain.index(later),
          throwsA(
            isA<RpcError>()
                .having((error) => error.code, 'code', RpcErrorCode.cancelled)
                .having((e) => e.message, 'message', 'Workspace closed'),
          ),
        );
        domain.close();
        store.close();
        storeClosed = true;
        await waiting.timeout(const Duration(seconds: 5));
      } finally {
        domain.close();
        if (!storeClosed) store.close();
        if (!service.release.isCompleted) service.release.complete();
        await helper.close();
        await server.shutdown();
        temporary.deleteSync(recursive: true);
      }
    },
  );

  test(
    'closing workspace cancels in-flight and queued indexing before database disposal',
    () async {
      final temporary = createTestTempDirectorySync('foresight-domain-close-');
      addTearDown(() {
        if (temporary.existsSync()) temporary.deleteSync(recursive: true);
      });
      final service = DelayedIndexService();
      final server = Server.create(services: [service]);
      final socket = '${temporary.path}/helper.sock';
      await server.serve(
        address: InternetAddress(socket, type: InternetAddressType.unix),
        port: 0,
      );
      final helper = Helper(socket, '${temporary.path}/helper'),
          store = Store('${temporary.path}/app.db');
      final domain = Domain(store, helper);
      final id = store.importText(
        'Fixture',
        'Keep this source.',
        'text/plain',
        'fixture',
      );
      try {
        final first = domain.index(id), queued = domain.index(id);
        final firstResult = expectLater(
          first,
          throwsA(
            isA<RpcError>()
                .having((error) => error.code, 'code', RpcErrorCode.cancelled)
                .having((e) => e.message, 'message', 'Workspace closed'),
          ),
        );
        final queuedResult = expectLater(
          queued,
          throwsA(
            isA<RpcError>()
                .having((error) => error.code, 'code', RpcErrorCode.cancelled)
                .having((e) => e.message, 'message', 'Workspace closed'),
          ),
        );
        await service.started.future.timeout(const Duration(seconds: 5));
        domain.close();
        store.close();
        service.release.complete();
        await Future.wait([firstResult, queuedResult]);
        expect(service.calls, 1);
      } finally {
        if (!service.release.isCompleted) service.release.complete();
        await helper.close();
        await server.shutdown();
        temporary.deleteSync(recursive: true);
      }
    },
  );
}
