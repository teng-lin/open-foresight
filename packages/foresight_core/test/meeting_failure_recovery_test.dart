import 'package:foresight_test_support/desktop_identity.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:test/test.dart';

class RecoveryHelper extends Helper {
  int launches = 0;
  RecoveryHelper(super.socket, super.storage);
  @override
  Future<void> start() async {
    launches++;
    await Future<void>(() {});
  }
}

class IndexingDomain extends Domain {
  final indexed = <String>[];
  IndexingDomain(super.store, super.helper);
  @override
  Future<void> index(String id, {bool Function()? current}) async {
    indexed.add(id);
    store.state(id, 'indexed');
  }
}

class FailedRecording extends Recording {
  FailedRecording()
    : super(
        Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6',
        (_) {},
        (_, _, _, _) {},
      );
  @override
  Future<void> stop() async =>
      throw StateError('transient speech worker failure');
}

void main() {
  late Application app;
  late Directory temp;
  late Store store;
  late RecoveryHelper helper;
  late IndexingDomain domain;
  setUp(() {
    temp = createTestTempDirectorySync('of-meeting-recovery-');
    store = Store('${temp.path}/application.db');
    helper = RecoveryHelper('${temp.path}/helper.sock', '${temp.path}/helper');
    domain = IndexingDomain(store, helper);
    app = Application(domain);
  });
  setUp(() {
    addTearDown(() async {
      await app.close();
      domain.close();
      await helper.close();
      store.close();
      temp.deleteSync(recursive: true);
    });
  });
  test(
    'speech stop failure retains, indexes and exposes committed transcript as recoverable',
    () async {
      final id = store.meeting('Partial meeting');
      store.transcript(
        id,
        'Already committed useful speech',
        true,
        0,
        1000,
        'microphone',
      );
      app.recording = FailedRecording();
      app.recordingMeeting = id;
      await app.stopRecording();
      expect(domain.indexed, ['meeting-$id']);
      expect(
        store.rows('SELECT state FROM meetings WHERE id=?', [
          id,
        ]).single['state'],
        'interrupted',
      );
      expect(
        store.sources.single['content'],
        contains('Already committed useful speech'),
      );
      expect(app.recording, isNull);
      expect(app.recordingState, contains('Transcript retained'));
    },
  );
  test(
    'application resume resets exhausted helper budget and coalesces recovery launches',
    () async {
      helper.restarts = 5;
      helper.state = 'unavailable';
      await Future.wait([
        app.call(Operation.applicationResume.wire, const {}),
        app.call(Operation.applicationResume.wire, const {}),
      ]);
      expect(helper.launches, 1);
      expect(helper.restarts, 0);
    },
  );
  test(
    'incompatible terminated helper is not reused by explicit recovery',
    () async {
      helper.incompatible = true;
      helper.restarts = 5;
      await expectLater(
        app.call(Operation.applicationResume.wire, const {}),
        throwsStateError,
      );
      expect(helper.launches, 0);
      expect(helper.restarts, 5);
    },
  );

  test('service startup marks a crash during pause interrupted', () async {
    final profile = ProfilePaths(
      '${temp.path}/service-data',
      '${temp.path}/service-run',
    );
    privateDirectory(profile.data);
    final owner = Store('${profile.data}/application.db');
    final id = owner.meeting('Paused during crash');
    owner.db.execute("UPDATE meetings SET state='paused' WHERE id=?", [id]);
    owner.close();
    final original = Map<String, String>.of(runtimeConfiguration.environment);
    for (final key in [
      'FORESIGHT_HELPER',
      'FORESIGHT_NATIVE',
      'FORESIGHT_INSTALL_ROOT',
      'FORESIGHT_RUNTIME_REVISION',
    ]) {
      runtimeConfiguration.environment.remove(key);
    }
    try {
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      try {
        expect(
          service.domain.store.rows('SELECT state FROM meetings WHERE id=?', [
            id,
          ]).single['state'],
          'interrupted',
        );
      } finally {
        await service.close();
      }
    } finally {
      runtimeConfiguration.environment
        ..clear()
        ..addAll(original);
    }
  });
}
