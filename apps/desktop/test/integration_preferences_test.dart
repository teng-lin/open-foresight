import 'dart:async';
import 'package:flutter/material.dart';
import '../test_support/core_fixture.dart';

import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/features/integrations/widgets.dart';
import '../test_support/reader_admissions.dart';
import 'controller_fixture.dart';
import 'store_reader_fixture.dart';
import 'pump_until.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/features/integrations/preferences.dart';

class _Reader implements StoreReader {
  @override
  String workspaceEpoch = 'epoch';
  @override
  String dataRevision = 'revision';
  final queries = <ReadQuery<Object?>>[];
  final replies = <StreamController<ReadResult<String>>>[];
  final pendingReads = <Completer<ReadResult<String>>>[];

  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) {
    final reply = Completer<ReadResult<String>>();
    pendingReads.add(reply);
    return reply.future.then((result) => result as ReadResult<T>);
  }

  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    queries.add(query);
    final controller = StreamController<ReadResult<String>>.broadcast(
      sync: true,
    );
    replies.add(controller);
    return controller.stream.map((result) => result as ReadResult<T>);
  }

  void emit(
    int index,
    String value, {
    ReadFreshness freshness = ReadFreshness.current,
  }) => replies[index].add(
    ReadResult(
      freshness: freshness,
      value: value,
      requestTag: dataRevision,
      sequence: 1,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection implements DesktopConnection {
  @override
  final _Reader store = _Reader();
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  @override
  Object clientSessionGeneration = Object();
  @override
  String? workspaceEpoch = 'epoch';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> dispose() async {
    await events.close();
    for (final reply in store.replies) {
      await reply.close();
    }
  }
}

void main() {
  testWidgets('prepared device controls and shortcut builders admit no reads', (
    tester,
  ) async {
    final root = createTestTempDirectorySync('integration-view-');
    final store = Store('${root.path}/app.db');
    store.setPreference('microphoneTarget', 'saved microphone');
    store.setPreference('quickShortcut', 'SUPER + SHIFT + M');
    final admissions = ReaderAdmissions();
    fixtureReader(store, admissions: admissions);
    final helper = OfflineHelper('${root.path}/socket', '${root.path}/helper');
    final connection = ControllerConnection(Application(Domain(store, helper)));
    final startupModel = IntegrationPreferenceModel(connection);
    expect(
      await tester.runAsync(() => startupModel.readCurrent('quickShortcut')),
      'SUPER + SHIFT + M',
    );
    startupModel.dispose();
    await tester.pumpWidget(
      Foresight(connection, deviceLoader: () async => []),
    );
    await tester.pumpAndSettle();
    final shell = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
    final controller = shell.integrationFeature;
    try {
      final before = admissions.snapshot();
      for (var i = 0; i < 20; i++) {
        final device =
            controller.deviceChoice(false) as IntegrationDeviceChoice;
        expect(device.current, 'saved microphone');
        expect(controller.quickActivator.meta, isTrue);
        expect(controller.quickActivator.shift, isTrue);
        helper.changed?.call();
      }
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      final after = admissions.snapshot();
      for (final boundary in ['read', 'watch', 'worker']) {
        expect(after[boundary], before[boundary], reason: boundary);
      }
      expect(
        after['sync']!['preference'],
        before['sync']!['preference'],
        reason: 'Device and shortcut builders use immutable prepared values',
      );
      store.setPreference('microphoneTarget', 'replacement microphone');
      helper.changed?.call();
      await tester.pumpAndSettle();
      expect(
        (controller.deviceChoice(false) as IntegrationDeviceChoice).current,
        'replacement microphone',
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      var closed = false;
      unawaited(connection.closed.then((_) => closed = true));
      await pumpUntil(tester, () => closed);
      root.deleteSync(recursive: true);
    }
  });

  late _Connection connection;
  late IntegrationPreferenceModel model;
  setUp(() {
    connection = _Connection();
    model = IntegrationPreferenceModel(connection);
  });
  tearDown(() async {
    model.dispose();
    await connection.dispose();
  });

  test('action reads work before watches and reject replaced owners', () async {
    final initial = model.readCurrent('quickShortcut');
    connection.store.pendingReads[0].complete(
      const ReadResult(
        freshness: ReadFreshness.current,
        value: 'ALT + SHIFT + M',
        requestTag: 'revision',
        sequence: 1,
      ),
    );
    expect(await initial, 'ALT + SHIFT + M');
    expect(connection.store.queries, isEmpty);
    final retired = model.readCurrent('quickShortcut');
    connection.clientSessionGeneration = Object();
    final rejected = expectLater(
      retired,
      throwsA(
        isA<RpcError>().having(
          (error) => error.code,
          'code',
          RpcErrorCode.cancelled,
        ),
      ),
    );
    connection.store.pendingReads[1].complete(
      const ReadResult(
        freshness: ReadFreshness.current,
        value: 'retired',
        requestTag: 'revision',
        sequence: 2,
      ),
    );
    await rejected;
  });

  test(
    'stable typed watches ignore status, equal values and stale previews',
    () {
      var notifications = 0;
      model.addListener(() => notifications++);
      model.start();
      model.start();
      expect(
        connection.store.queries.map((query) => query.projection),
        everyElement('preference'),
      );
      expect(
        connection.store.queries.map((query) => query.arguments['key']),
        IntegrationPreferences.defaults.keys,
      );
      expect(connection.store.queries, hasLength(4));
      for (var i = 0; i < 20; i++) connection.events.add(null);
      expect(connection.store.queries, hasLength(4));
      connection.store.emit(2, 'auto');
      expect(notifications, 0);
      connection.store.emit(2, 'microphone');
      expect(model.value.value('microphoneTarget'), 'microphone');
      expect(notifications, 1);
      connection.store.emit(2, 'microphone');
      expect(
        notifications,
        1,
        reason: 'New value-equal snapshots do not rebuild',
      );
      connection.store.emit(2, 'retired', freshness: ReadFreshness.preview);
      connection.store.emit(2, 'busy', freshness: ReadFreshness.busy);
      expect(model.value.value('microphoneTarget'), 'microphone');
      expect(notifications, 1);
      connection.store.dataRevision = 'next-revision';
      connection.events.add(null);
      expect(
        connection.store.queries,
        hasLength(4),
        reason: 'Data revisions retain active query ownership',
      );
      connection.store.emit(2, 'new microphone');
      expect(model.value.value('microphoneTarget'), 'new microphone');
    },
  );

  test(
    'session replacement retires held old subscriptions at the same epoch',
    () {
      model.start();
      connection.store.emit(2, 'old microphone');
      connection.clientSessionGeneration = Object();
      connection.events.add(null);
      expect(model.value.value('microphoneTarget'), 'auto');
      expect(
        connection.store.replies.take(4).any((reply) => reply.hasListener),
        false,
      );
      expect(connection.store.queries, hasLength(8));
      connection.store.emit(2, 'late old microphone');
      expect(model.value.value('microphoneTarget'), 'auto');
      connection.store.emit(6, 'replacement microphone');
      expect(model.value.value('microphoneTarget'), 'replacement microphone');
    },
  );

  test(
    'clear blocks unadopted results and rebinds after workspace adoption',
    () {
      model.start();
      connection.store.emit(2, 'before clear');
      connection.store.workspaceEpoch = 'cleared';
      connection.events.add(null);
      expect(model.value.value('microphoneTarget'), 'auto');
      connection.store.emit(6, 'unadopted');
      expect(model.value.value('microphoneTarget'), 'auto');
      connection.workspaceEpoch = 'cleared';
      connection.events.add(null);
      expect(connection.store.queries, hasLength(12));
      connection.store.emit(10, 'after clear');
      expect(model.value.value('microphoneTarget'), 'after clear');
    },
  );

  test('dispose cancels each owned subscription and rejects later events', () {
    model.start();
    model.dispose();
    model.dispose();
    expect(connection.events.hasListener, false);
    expect(connection.store.replies.any((reply) => reply.hasListener), false);
    connection.store.emit(2, 'late microphone');
    connection.events.add(null);
    model.start();
    expect(connection.store.queries, hasLength(4));
    expect(model.value.value('microphoneTarget'), 'auto');
  });
}
