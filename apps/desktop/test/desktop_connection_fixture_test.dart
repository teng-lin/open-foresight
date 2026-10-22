import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';

import 'desktop_connection_fixture.dart';

class ReadinessHelper extends Helper {
  ReadinessHelper(super.socket, super.storage, this.ready);
  final bool ready;
  @override
  Future<void> start() async {
    state = ready ? 'live' : 'disconnected';
    if (ready) await onReady?.call();
  }
}

class ResumeDomain extends Domain {
  ResumeDomain(super.store, super.helper);
  int resumes = 0;
  @override
  Future<void> resume() async => resumes++;
}

void main() {
  for (final ready in [false, true]) {
    test('fixture initializes only after helper readiness ($ready)', () async {
      final Directory directory = createTestTempDirectorySync('fixture-ready-');
      final domain = ResumeDomain(
        Store('${directory.path}/application.db'),
        ReadinessHelper(
          '${directory.path}/socket',
          '${directory.path}/helper',
          ready,
        ),
      );
      final connection = TestDesktopConnection(Application(domain));
      final initialSession = connection.clientSessionGeneration;
      try {
        final initialization = connection.initialize();
        expect(connection.initialize(), same(initialization));
        if (!ready) {
          var initialized = false;
          unawaited(initialization.then((_) => initialized = true));
          await Future<void>.delayed(Duration.zero);
          expect(initialized, isFalse);
          expect(domain.resumes, 0);
          // A later owner readiness notification admits the pending initializer.
          await domain.helper.onReady!();
        }
        await initialization;
        await connection.resume();
        expect(domain.resumes, 1);
        expect(connection.clientSessionGeneration, same(initialSession));
        final observed = <Object>[];
        final changes = connection.changes.listen((_) {
          observed.add(connection.clientSessionGeneration);
        });
        domain.helper.changed?.call();
        expect(observed, [same(initialSession)]);
        connection.replaceClientSessionForTesting();
        final replacement = connection.clientSessionGeneration;
        expect(replacement, isNot(same(initialSession)));
        expect(observed, [same(initialSession), same(replacement)]);
        domain.helper.changed?.call();
        expect(observed.last, same(replacement));
        await changes.cancel();
      } finally {
        connection.close();
        await connection.closed;
        directory.deleteSync(recursive: true);
      }
    });
  }
  test('closing settles an initializer waiting for helper readiness', () async {
    final directory = createTestTempDirectorySync('fixture-ready-close-');
    final domain = ResumeDomain(
      Store('${directory.path}/application.db'),
      ReadinessHelper(
        '${directory.path}/socket',
        '${directory.path}/helper',
        false,
      ),
    );
    final connection = TestDesktopConnection(Application(domain));
    final initialization = connection.initialize();
    final rejected = expectLater(
      initialization,
      throwsA(
        isA<RpcError>().having(
          (error) => error.code,
          'code',
          RpcErrorCode.cancelled,
        ),
      ),
    );
    connection.close();
    await connection.closed;
    await rejected;
    expect(domain.resumes, 0);
    directory.deleteSync(recursive: true);
  });
}
