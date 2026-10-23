import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/features/chat/chat_controller.dart';
import 'package:open_foresight/features/chat/read_model.dart';
import 'package:open_foresight/shell/ports.dart';
import 'package:open_foresight/shell/workspace_tab.dart';

class _Reader implements StoreReader {
  @override
  String workspaceEpoch = 'epoch';
  @override
  String dataRevision = '1';
  AnswerScopeSnapshot scope = AnswerScopeSnapshot(mode: 'workspace', ids: null);
  final queries = <ReadQuery<Object?>>[];
  final scopes = <StreamController<ReadResult<AnswerScopeSnapshot>>>[];
  final histories = <StreamController<ReadResult<List<SavedAnswer>>>>[];

  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    queries.add(query);
    if (query.projection == 'answer_scope') {
      final controller =
          StreamController<ReadResult<AnswerScopeSnapshot>>.broadcast(
            sync: true,
          );
      scopes.add(controller);
      scheduleMicrotask(() {
        if (controller.hasListener) controller.add(_result(scope));
      });
      return controller.stream.map((result) => result as ReadResult<T>);
    }
    if (query.projection != 'answers')
      throw StateError('Unexpected query ${query.projection}');
    final controller =
        StreamController<ReadResult<List<SavedAnswer>>>.broadcast(sync: true);
    histories.add(controller);
    scheduleMicrotask(() {
      if (controller.hasListener)
        controller.add(_result(const <SavedAnswer>[]));
    });
    return controller.stream.map((result) => result as ReadResult<T>);
  }

  ReadResult<T> _result<T>(T value) => ReadResult(
    freshness: ReadFreshness.current,
    value: value,
    requestTag: dataRevision,
    sequence: 1,
  );
  void settleScope() {
    for (final controller in scopes) {
      if (controller.hasListener) controller.add(_result(scope));
    }
  }

  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) async =>
      _result(scope as T);
  Future<void> close() async {
    for (final controller in scopes) await controller.close();
    for (final controller in histories) await controller.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection implements DesktopConnection {
  @override
  final _Reader store = _Reader();
  @override
  Object clientSessionGeneration = Object();
  @override
  String? workspaceEpoch = 'epoch';
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  @override
  bool get webSearchAvailable => false;
  final response = StreamController<String>.broadcast(sync: true);
  final entered = Completer<void>();
  final prompts = <(String, String)>[];
  @override
  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  }) async* {
    prompts.add((question, conversation));
    if (!entered.isCompleted) entered.complete();
    yield* response.stream;
  }

  Future<void> dispose() async {
    await response.close();
    await events.close();
    await store.close();
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
  DesktopEnvironment get environment => const DesktopEnvironment();
  int updates = 0;
  @override
  void update(VoidCallback action) {
    updates++;
    action();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Navigation implements WorkspaceNavigation {
  @override
  WorkspaceTab selectedTab = WorkspaceTab.chat;
  @override
  void navigate(WorkspaceTab destination) => selectedTab = destination;
}

class _Gate implements OperationGate {
  int admissions = 0;
  @override
  bool get busy => false;
  @override
  Future<void> run(Future<void> Function() action) {
    admissions++;
    return action();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Meetings implements MeetingActivity {
  @override
  bool get meetingEnhancing => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sources implements SourceCommands {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _Connection connection;
  late _Host host;
  late _Gate gate;
  late ChatController controller;
  setUp(() {
    connection = _Connection();
    host = _Host(connection);
    gate = _Gate();
    controller = ChatController(
      host: host,
      navigation: _Navigation(),
      operations: gate,
      meetings: _Meetings(),
      sources: _Sources(),
    );
  });
  tearDown(() async {
    controller.dispose();
    host.mounted = false;
    await connection.dispose();
  });

  test('feature runs with narrow fake ports and typed queries only', () async {
    controller.attach(null);
    await _settle();
    expect(connection.store.queries.map((query) => query.projection), [
      'answer_scope',
      'answers',
    ]);
    void publishHistory() => connection.store.histories.single.add(
      ReadResult(
        freshness: ReadFreshness.current,
        requestTag: '1',
        sequence: 1,
        value: [
          SavedAnswer.fromRow({
            'id': 1,
            'question': 'Saved question',
            'body': 'Saved answer',
            'status': 'completed',
            'citations':
                '[{"citation":"S1","document_id":"source","revision":1,"excerpt":"Evidence"}]',
          }),
        ],
      ),
    );
    publishHistory();
    await _settle();
    final before = host.updates;
    publishHistory();
    await _settle();
    expect(
      host.updates,
      before,
      reason: 'New value-equal history and citations do not notify',
    );
    for (var i = 0; i < 20; i++) controller.buildConversation();
    expect(
      connection.store.queries,
      hasLength(2),
      reason: 'Builders admit no persistence queries',
    );
    for (var i = 0; i < 20; i++) connection.events.add(null);
    connection.store.settleScope();
    await _settle();
    expect(connection.store.queries, hasLength(2));
    expect(
      host.updates,
      before,
      reason: 'Equal projections and status events do not notify',
    );
    controller.setQuestion(null, 'Isolated question');
    final work = controller.askQuestion();
    await connection.entered.future;
    connection.response.add('Isolated answer');
    await _settle();
    expect(controller.answer, 'Isolated answer');
    expect(controller.questionFor(null).text, isEmpty);
    expect(gate.admissions, 1);
    expect(connection.prompts, [('Isolated question', 'desktop')]);
    await connection.response.close();
    await work;
    controller.detach(null);
    expect(connection.store.scopes.any((stream) => stream.hasListener), false);
    expect(
      connection.store.histories.any((stream) => stream.hasListener),
      false,
    );
  });

  for (final changed in [false, true]) {
    test(
      'held scope verification ${changed ? 'rejects a changed scope' : 'keeps an unrelated commit alive'}',
      () async {
        controller.attach(null);
        await _settle();
        controller.setQuestion(null, 'Question before commit');
        final work = controller.askQuestion();
        await connection.entered.future;
        connection.response.add('Accepted preview');
        await _settle();
        expect(controller.answer, 'Accepted preview');
        connection.store.dataRevision = '2';
        if (changed)
          connection.store.scope = AnswerScopeSnapshot(
            mode: 'selected',
            ids: {},
          );
        connection.events.add(null);
        connection.response.add('Text after commit');
        await _settle();
        expect(
          controller.answer,
          'Accepted preview',
          reason: 'Text waits for actual scope verification',
        );
        expect(
          connection.store.queries,
          hasLength(2),
          reason: 'Ordinary revisions retain scheduling entries',
        );
        connection.store.settleScope();
        await _settle();
        expect(controller.answer, changed ? '' : 'Text after commit');
        expect(connection.store.queries, hasLength(changed ? 3 : 2));
        await connection.response.close();
        await work;
        expect(controller.asking, false);
      },
    );
  }

  test(
    'session replacement cancels temporary action validation subscriptions',
    () async {
      final model = ChatConversationModel(connection, null);
      addTearDown(model.dispose);
      model.start();
      await _settle();
      connection.store.dataRevision = '2';
      final pending = model.currentScope();
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
      expect(connection.store.scopes, hasLength(2));
      connection.clientSessionGeneration = Object();
      connection.events.add(null);
      expect(
        connection.store.scopes.take(2).any((stream) => stream.hasListener),
        false,
      );
      await rejected;
      await _settle();
      expect((await model.currentScope()).mode, 'workspace');
    },
  );

  test(
    'failed scope reads settle later admissions without retaining a waiter',
    () async {
      final model = ChatConversationModel(connection, null);
      addTearDown(model.dispose);
      model.start();
      await _settle();
      final failure = RpcError(RpcErrorCode.busy, 'Held reader failed');
      connection.store.scopes.single.add(
        ReadResult(
          freshness: ReadFreshness.failed,
          value: null,
          error: failure,
          requestTag: '1',
          sequence: 2,
        ),
      );
      var failed = false;
      unawaited(
        model.currentScope().then<void>(
          (_) {},
          onError: (Object error) {
            expect(error, same(failure));
            failed = true;
          },
        ),
      );
      await _settle();
      expect(failed, true);
      expect(model.value.error, contains('Held reader failed'));
      connection.store.settleScope();
      expect(model.value.error, isEmpty);
      expect((await model.currentScope()).mode, 'workspace');
    },
  );

  test('dispose retires a producer waiting for scope verification', () async {
    controller.attach(null);
    await _settle();
    controller.setQuestion(null, 'Retired question');
    final work = controller.askQuestion();
    await connection.entered.future;
    connection.store.dataRevision = '2';
    connection.events.add(null);
    connection.response.add('Late text');
    await _settle();
    controller.dispose();
    await _settle();
    await connection.response.close();
    await work;
    expect(controller.answer, isEmpty);
    expect(connection.store.scopes.any((stream) => stream.hasListener), false);
  });
}
