import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
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
    test('fixture resumes only after helper readiness ($ready)', () async {
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
      try {
        await connection.initialize();
        await connection.resume();
        expect(domain.resumes, ready ? 1 : 0);
        if (!ready) {
          // A later owner readiness notification admits the pending resume.
          await domain.helper.onReady!();
          await connection.resume();
          expect(domain.resumes, 1);
        }
      } finally {
        connection.close();
        await connection.closed;
        directory.deleteSync(recursive: true);
      }
    });
  }
}
