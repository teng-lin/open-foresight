import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:test/test.dart';

import 'application_operations_test.dart' show ArtifactGenerator;

class RpcArtifactRuntime extends ArtifactGenerator {
  final cancelled = Completer<String?>();
  @override
  bool cancel({String? requestId}) {
    if (!cancelled.isCompleted) cancelled.complete(requestId);
    return true;
  }
}

void main() {
  for (final kind in ['summary', 'actions', 'questions']) {
    test(
      'RPC cancellation of $kind cannot persist its late artifact',
      () async {
        final environment = Map.of(runtimeConfiguration.environment);
        for (final key in [
          'FORESIGHT_NATIVE',
          'FORESIGHT_RUNTIME_REVISION',
          'FORESIGHT_INSTALL_ROOT',
        ]) {
          runtimeConfiguration.environment.remove(key);
        }
        runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
        final root = createTestTempDirectorySync('rpc-cancellation-');
        final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
        final service = await ApplicationService.start(profile);
        final client = await ServiceClient.connect(
          '${profile.runtime}/application.sock',
        );
        final runtime = RpcArtifactRuntime()
          ..entered = Completer<void>()
          ..release = Completer<void>();
        service.domain.generator = runtime;
        final meeting = service.domain.store.meeting('Cancellation');
        service.domain.store.transcript(
          meeting,
          'Private meeting facts',
          true,
          0,
          1,
          'imported',
        );
        StreamSubscription<Object?>? subscription;
        try {
          final failure = Completer<void>();
          subscription = client
              .stream('meetings.generate', {
                'id': meeting,
                'kind': kind,
                'requestId': 'client-$kind',
              })
              .listen(
                (_) {},
                onError: (Object _) {
                  failure.complete();
                },
              );
          await runtime.entered!.future.timeout(const Duration(seconds: 3));
          expect(client.cancelAnswers(requestId: 'client-$kind'), isTrue);
          await failure.future;
          final cancelledId = await runtime.cancelled.future.timeout(
            const Duration(seconds: 3),
          );
          expect(cancelledId, runtime.requestIds.single);
          runtime.release!.complete();
          // The ordinary command round trip runs after the lease cancellation.
          await client.call('status');
          await Future<void>.delayed(Duration.zero);
          expect(service.domain.store.rows('SELECT * FROM artifacts'), isEmpty);
        } finally {
          if (!runtime.release!.isCompleted) runtime.release!.complete();
          await subscription?.cancel();
          await client.close();
          await service.close();
          root.deleteSync(recursive: true);
          runtimeConfiguration.environment
            ..clear()
            ..addAll(environment);
        }
      },
    );
  }
}
