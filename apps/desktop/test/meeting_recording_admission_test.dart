import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/features/meetings/read_model.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/features/meetings/meetings_controller.dart';
import 'package:open_foresight/shell/ports.dart';
import 'package:open_foresight/shell/workspace_tab.dart';

class _Reader implements StoreReader {
  late final replies =
      StreamController<ReadResult<ModelRegistration?>>.broadcast(
        sync: true,
        onListen: () => active++,
        onCancel: () => active--,
      );
  int active = 0;
  @override
  String workspaceEpoch = 'workspace';
  @override
  String dataRevision = '1';
  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) =>
      replies.stream.map((reply) => reply.asType<T>());
  void reply(
    ModelRegistration? model,
    ReadFreshness freshness, {
    RpcError? error,
  }) => replies.add(
    ReadResult(
      freshness: freshness,
      value: model,
      error: error,
      requestTag: 'speech',
      sequence: 1,
    ),
  );
  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) async => ReadResult<T>(
    freshness: ReadFreshness.preview,
    value: null,
    requestTag: 'old-one-shot',
    sequence: 0,
  );
  Future<void> close() async {
    await replies.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection implements DesktopConnection {
  @override
  final _Reader store = _Reader();
  final events = StreamController<void>.broadcast(sync: true);
  final sent = <Operation>[];
  final arguments = <Map<String, dynamic>>[];
  @override
  Stream<void> get changes => events.stream;
  @override
  String? workspaceEpoch = 'workspace';
  @override
  Object clientSessionGeneration = Object();
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    sent.add(operation);
    this.arguments.add(Map.of(arguments));
    return operation == Operation.meetingsCreate
        ? <String, Object?>{'id': 7}
        : <String, Object?>{};
  }

  @override
  Future<Object?> commandCurrent(
    Operation operation,
    Map<String, dynamic> arguments,
    bool Function() current,
  ) {
    if (!current()) throw StateError('superseded fixture command');
    return command(operation, arguments);
  }

  @override
  Future<void> close() async {
    await store.close();
    await events.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Host implements FeatureHost {
  _Host(this.connection);
  @override
  final _Connection connection;
  @override
  bool mounted = true;
  @override
  void update(VoidCallback action) => action();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Operations implements OperationGate {
  final failures = <Object>[];
  @override
  bool get busy => false;
  @override
  String get error => '';
  @override
  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (failure) {
      failures.add(failure);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Ports
    implements
        WorkspaceNavigation,
        WorkspaceDialogs,
        IntegrationActivity,
        IntegrationCommands,
        SettingsCommands,
        ChatActivity,
        ChatCommands {
  int prompts = 0;
  @override
  void navigate(WorkspaceTab destination) {}
  @override
  Future<bool> ensureRecordingAccess() async => true;
  @override
  Future<void> chooseSpeech() async {
    prompts++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends MeetingsController {
  _Controller(_Host host, _Operations operations, _Ports ports)
    : super(
        host: host,
        navigation: ports,
        operations: operations,
        dialogs: ports,
        integrations: ports,
        integrationCommands: ports,
        settings: ports,
        chat: ports,
        chatCommands: ports,
      );
  @override
  void syncCapture() {}
}

void main() {
  late _Connection connection;
  late _Operations operations;
  late _Controller controller;
  late _Ports ports;
  late Directory root;
  late ModelRegistration model;
  setUp(() async {
    root = await createTestTempDirectory('recording-');
    final asset = await File(
      '${root.path}/model',
    ).writeAsString('synthetic registration only');
    model = ModelRegistration.fromRow({
      'kind': 'speech',
      'path': asset.path,
      'runtime': Platform.resolvedExecutable,
    });
    connection = _Connection();
    operations = _Operations();
    ports = _Ports();
    controller = _Controller(_Host(connection), operations, ports);
  });
  tearDown(() async {
    await controller.dispose();
    await connection.close();
  });
  for (final quick in [false, true]) {
    test(
      '${quick ? 'quick' : 'existing'} record action waits through preview then sends exactly one start',
      () async {
        final action = quick
            ? controller.quickStart()
            : controller.recordExistingMeeting(7);
        await Future<void>.delayed(Duration.zero);
        connection.store.reply(model, ReadFreshness.preview);
        await Future<void>.delayed(Duration.zero);
        expect(connection.sent, isEmpty);
        expect(operations.failures, isEmpty);
        expect(controller.quickStarting, isTrue);
        connection.store.reply(model, ReadFreshness.current);
        await Future<void>.delayed(Duration.zero);
        await action;
        expect(connection.sent, [
          if (quick) Operation.meetingsCreate,
          Operation.meetingsStart,
        ]);
        expect(connection.arguments.last['id'], 7);
        expect(operations.failures, isEmpty);
        expect(ports.prompts, 0);
        expect(connection.store.active, 0);
      },
    );
  }
  for (final change in ['session', 'epoch', 'selection', 'dispose']) {
    test('$change cancels waiting recording admission promptly', () async {
      final action = controller.recordExistingMeeting(7);
      await Future<void>.delayed(Duration.zero);
      if (change == 'session') {
        connection.clientSessionGeneration = Object();
        connection.events.add(null);
      } else if (change == 'epoch') {
        connection.store.workspaceEpoch = 'replaced';
        connection.events.add(null);
      } else if (change == 'selection') {
        controller.meetingId = 9;
      } else {
        await controller.dispose();
      }
      await Future<void>.delayed(Duration.zero);
      await action;
      expect(connection.store.active, 0);
      expect(connection.sent, isEmpty);
      expect(ports.prompts, 0);
      expect(operations.failures, isEmpty);
    });
  }
  test('selection setters remain harmless after disposal', () async {
    await controller.dispose();
    expect(() {
      controller.meetingId = 1;
      controller.meetingPreviewId = 2;
    }, returnsNormally);
  });
  test('concrete read failure is preserved without dispatch', () async {
    final failure = RpcError(RpcErrorCode.internal, 'controlled read failure');
    final action = controller.recordExistingMeeting(7);
    await Future<void>.delayed(Duration.zero);
    connection.store.reply(null, ReadFreshness.failed, error: failure);
    await Future<void>.delayed(Duration.zero);
    await action;
    expect(operations.failures.single, same(failure));
    expect(connection.sent, isEmpty);
    expect(connection.store.active, 0);
  });
  testWidgets(
    'continuous preview cannot extend the overall thirty second budget',
    (tester) async {
      final reader = _Reader();
      final pending = readCurrentRecordingSetup(
        reader,
        StoreReadQueries.model('speech'),
        current: () => true,
        ownerChanges: const [],
      );
      final checked = expectLater(
        pending,
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            RpcErrorCode.unavailable,
          ),
        ),
      );
      for (var second = 0; second < 30; second++) {
        reader.reply(model, ReadFreshness.preview);
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.runAsync(() => checked);
      expect(reader.active, 0);
      await tester.runAsync(reader.close);
    },
  );
}
