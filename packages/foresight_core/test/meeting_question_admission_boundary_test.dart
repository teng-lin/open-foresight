import 'dart:io';

import 'package:foresight_core/src/application_services/generation_coordinator.dart';
import 'package:foresight_core/src/application_services/meeting_questions.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/persistence/meeting_queries.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Store store;
  late Helper helper;
  late Domain domain;
  late GenerationCoordinator coordinator;
  late MeetingQuestions questions;
  late int meeting;
  setUp(() {
    root = createTestTempDirectorySync('meeting-question-admission-');
    store = Store('${root.path}/app.db');
    helper = Helper(
      '${root.path}/unused.sock',
      '${root.path}/unused',
      manageProcess: false,
    );
    domain = Domain(store, helper);
    coordinator = GenerationCoordinator(
      restoring: () => false,
      generating: () => false,
      recording: () => false,
      closed: () => false,
      yieldAutomatic: () async {},
    );
    questions = MeetingQuestions(
      domain: domain,
      coordinator: coordinator,
      meetings: MeetingQueries(store.db, supportedVersion: Store.schemaVersion),
      modelDigest: () => 'unused',
    );
    meeting = store.meeting('Owned question preparation');
    store.transcript(
      meeting,
      'Who will own the launch?',
      true,
      0,
      1000,
      'microphone',
    );
    addTearDown(() async {
      domain.close();
      await helper.close();
      store.close();
      root.deleteSync(recursive: true);
    });
  });
  Matcher code(RpcErrorCode code) =>
      isA<RpcError>().having((e) => e.code, 'code', code);

  test(
    'cancelled question preparation refuses before lookup and after admission await',
    () async {
      await expectLater(
        questions.generate(meeting + 100, current: () => false),
        throwsA(code(RpcErrorCode.cancelled)),
      );
      var checks = 0;
      await expectLater(
        questions.generate(meeting, current: () => ++checks == 1),
        throwsA(code(RpcErrorCode.cancelled)),
      );
      expect(store.meetingArtifacts(meeting, 'questions'), isEmpty);
      expect(coordinator.busy, isFalse);
    },
  );

  test(
    'configuration and foreground reservations reject competing question work without releasing ownership',
    () async {
      final configuration = coordinator.configure();
      try {
        await expectLater(
          questions.generate(meeting),
          throwsA(code(RpcErrorCode.busy)),
        );
        expect(coordinator.owns(configuration), isTrue);
      } finally {
        configuration.settle();
      }
      final foreground = coordinator.reserve('other-owned-work', cancel: () {});
      try {
        await expectLater(
          questions.generate(meeting),
          throwsA(code(RpcErrorCode.busy)),
        );
        expect(coordinator.owns(foreground), isTrue);
      } finally {
        foreground.settle();
      }
      expect(coordinator.busy, isFalse);
      expect(store.meetingArtifacts(meeting, 'questions'), isEmpty);
    },
  );

  test(
    'missing generator refuses cleanly after transcript admission',
    () async {
      await expectLater(
        questions.generate(meeting),
        throwsA(code(RpcErrorCode.unavailable)),
      );
      expect(store.meetingArtifacts(meeting, 'questions'), isEmpty);
      expect(coordinator.busy, isFalse);
      expect(
        store.rows('SELECT text FROM transcript').single['text'],
        'Who will own the launch?',
      );
    },
  );
}
