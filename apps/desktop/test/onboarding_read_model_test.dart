import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/features/onboarding/onboarding_controller.dart';
import 'package:open_foresight/shell/ports.dart';
import 'package:open_foresight/shell/workspace_tab.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/features/onboarding/read_model.dart';

class _Reader implements StoreReader {
  final queries = <ReadQuery<Object?>>[];
  final streams = <StreamController<ReadResult<Object?>>>[];
  int active = 0;
  @override
  String workspaceEpoch = 'epoch';
  @override
  String dataRevision = '1';
  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    queries.add(query);
    final stream = StreamController<ReadResult<Object?>>.broadcast(
      sync: true,
      onListen: () => active++,
      onCancel: () => active--,
    );
    streams.add(stream);
    return stream.stream.map((value) => value.asType<T>());
  }

  void reply(
    int index,
    Object? value, {
    ReadFreshness freshness = ReadFreshness.current,
    RpcError? error,
  }) => streams[index].add(
    ReadResult(
      freshness: freshness,
      value: value,
      error: error,
      requestTag: 'test',
      sequence: index,
    ),
  );
  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) async {
    return ReadResult(
      freshness: nextFreshness,
      value: null,
      error: nextError,
      requestTag: 'single',
      sequence: 0,
    );
  }

  ReadFreshness nextFreshness = ReadFreshness.current;
  RpcError? nextError;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected synchronous projection: ${invocation.memberName}',
  );
}

class _Connection implements DesktopConnection {
  _Connection(this.store);
  @override
  final _Reader store;
  @override
  String? workspaceEpoch = 'epoch';
  @override
  Object clientSessionGeneration = Object();
  final calls = <(Operation, Map<String, dynamic>)>[];
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    calls.add((operation, Map.of(args)));
    for (var i = 0; i < store.queries.length; i++) {
      final query = store.queries[i];
      if (operation == Operation.preferencesSet &&
          query.projection == 'preference' &&
          query.arguments['key'] == args['key']) {
        store.reply(i, args['value']);
      }
    }
    return null;
  }

  // Closed by each owning fixture after subscriptions retire.
  // ignore: close_sinks
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<void> _close(
  _Reader reader,
  _Connection connection,
  OnboardingReadModel model,
) async {
  await model.dispose();
  for (final stream in reader.streams) {
    await stream.close();
  }
  await connection.events.close();
}

void _ready(_Reader reader, {int offset = 0, String complete = 'false'}) {
  reader.reply(offset, complete);
  reader.reply(offset + 1, '5');
  reader.reply(offset + 2, <SourceSummary>[]);
  reader.reply(offset + 3, null);
}

class _Host
    implements
        FeatureHost,
        WorkspaceNavigation,
        OperationGate,
        WorkspaceLifecycle {
  _Host(this.connection);
  @override
  final _Connection connection;
  @override
  late BuildContext context;
  @override
  bool mounted = false;
  @override
  final environment = const DesktopEnvironment();
  @override
  get commands => null;
  @override
  final ValueNotifier<int> serviceUiRevision = ValueNotifier<int>(0);
  @override
  final ValueNotifier<List<double>> captureVolumes =
      ValueNotifier<List<double>>(const []);
  @override
  WorkspaceTab selectedTab = WorkspaceTab.meetings;
  @override
  bool busy = false;
  @override
  String error = '';
  @override
  bool clearingWorkspace = false;
  late StateSetter rebuild;
  @override
  void update(VoidCallback action) {
    if (mounted) rebuild(action);
  }

  @override
  void navigate(WorkspaceTab value) => selectedTab = value;
  @override
  void setError(String value) => error = value;
  @override
  void reportAsyncError(Object failure) => error = '$failure';
  @override
  Future<void> run(Future<void> Function() action) async => action();
  @override
  void setClearingWorkspace(bool value) => clearingWorkspace = value;
  @override
  void resetWorkspaceViews() {}
  @override
  void serviceChanged() => update(() {});
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected host capability ${invocation.memberName}');
}

class _Settings implements SettingsCommands {
  @override
  Widget gemmaSetup({
    bool firstRun = false,
    bool embeddingOnly = false,
    VoidCallback? onDone,
  }) => const Text('Fixture model setup');
  @override
  Widget speechSetup({VoidCallback? onDone}) =>
      const Text('Fixture speech setup');
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Sources implements SourceCommands {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Integrations implements IntegrationsPort {
  @override
  GooglePresentation get googlePresentation => GooglePresentation.fromWire({});
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  testWidgets(
    'Onboarding mounts with fake ports and retires late action results',
    (tester) async {
      final connection = _Connection(_Reader());
      // The host owns only a read capability; no writable Store or Workspace.
      final host = _Host(connection);
      final controller = OnboardingController(
        host: host,
        navigation: host,
        operations: host,
        lifecycle: host,
        settings: _Settings(),
        sources: _Sources(),
        integrations: _Integrations(),
      )..ready = true;
      controller.start();
      _ready(connection.store);
      connection.store.reply(1, '0');
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, rebuild) {
              host.context = context;
              host.rebuild = rebuild;
              host.mounted = true;
              return Scaffold(body: controller.build());
            },
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        host.mounted = false;
        controller.dispose();
        for (final stream in connection.store.streams) {
          await stream.close();
        }
        await connection.events.close();
        host.serviceUiRevision.dispose();
        host.captureVolumes.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpAndSettle();
      expect(find.text('Start Foresight'), findsOneWidget);
      await tester.tap(find.text('Start Foresight'));
      await tester.pumpAndSettle();
      expect(find.text('Fixture model setup'), findsOneWidget);
      expect(connection.calls.last.$1, Operation.preferencesSet);
      expect(connection.calls.last.$2, {
        'key': 'onboarding.step',
        'value': '1',
      });
      final old = Completer<void>();
      final oldAction = controller.perform(() => old.future);
      expect(controller.working, true);
      connection.clientSessionGeneration = Object();
      connection.events.add(null);
      _ready(connection.store, offset: 4);
      await tester.pump();
      expect(controller.working, false);
      final replacement = Completer<void>();
      final replacementAction = controller.perform(() => replacement.future);
      old.completeError(StateError('Retired setup action'));
      await tester.pump();
      await oldAction;
      expect(controller.failure, isEmpty);
      expect(controller.working, true);
      replacement.complete();
      await tester.pump();
      await replacementAction;
      expect(controller.working, false);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'prepared setup uses stable factories and suppresses equal values',
    () async {
      final reader = _Reader();
      final connection = _Connection(reader);
      var publications = 0;
      final model = OnboardingReadModel(
        connection: () => connection,
        changed: () => publications++,
      );
      model.start();
      expect(reader.queries.map((q) => q.key), [
        StoreReadQueries.preference('onboarding.complete').key,
        StoreReadQueries.preference('onboarding.step', '0').key,
        StoreReadQueries.sources().key,
        StoreReadQueries.model('embedding').key,
      ]);
      expect(model.preferencesReady, false);
      reader.reply(0, 'true', freshness: ReadFreshness.preview);
      expect(model.complete, false);
      expect(model.preferencesReady, false);
      _ready(reader);
      await Future<void>(() {});
      expect(model.preferencesReady, true);
      expect(model.step, 5);
      SourceSummary source([String title = 'Saved source']) =>
          SourceSummary.fromRow({
            'id': 'source',
            'title': title,
            'state': 'pending',
            'error': '',
            'revision': 1,
          });
      reader.reply(2, [source()]);
      await Future<void>(() {});
      final snapshot = model.sources, count = publications;
      reader.reply(2, [source()]);
      reader.reply(0, 'false');
      reader.reply(1, '5');
      reader.reply(3, null);
      await Future<void>(() {});
      expect(publications, count);
      expect(model.sources, same(snapshot));
      reader.dataRevision = 'next';
      connection.events.add(null);
      await Future<void>(() {});
      expect(reader.queries, hasLength(4));
      reader.reply(2, [source('Changed source')]);
      await Future<void>(() {});
      expect(model.sources.single.title, 'Changed source');
      expect(publications, count + 1);
      await _close(reader, connection, model);
      expect(reader.active, 0);
    },
  );

  test('session and epoch replacements retire held setup values', () async {
    final reader = _Reader();
    final connection = _Connection(reader);
    final model = OnboardingReadModel(
      connection: () => connection,
      changed: () {},
    );
    model.start();
    _ready(reader);
    await Future<void>(() {});
    final owner = model.ownerKey;
    connection.clientSessionGeneration = Object();
    connection.events.add(null);
    await Future<void>(() {});
    expect(model.ownerKey, isNot(same(owner)));
    expect(model.preferencesReady, false);
    expect(reader.active, 4);
    reader.reply(0, 'true');
    reader.reply(1, '4');
    expect(model.complete, false);
    expect(model.preferencesReady, false);
    _ready(reader, offset: 4, complete: 'true');
    expect(model.complete, true);
    reader.workspaceEpoch = connection.workspaceEpoch = 'replacement';
    connection.events.add(null);
    await Future<void>(() {});
    expect(model.complete, false);
    expect(model.preferencesReady, false);
    expect(reader.active, 4);
    reader.reply(4, 'true');
    expect(model.complete, false);
    await _close(reader, connection, model);
  });

  test(
    'read failure can be retried and disposed watches cannot publish',
    () async {
      final reader = _Reader();
      final connection = _Connection(reader);
      var updates = 0;
      final model = OnboardingReadModel(
        connection: () => connection,
        changed: () => updates++,
      );
      model.start();
      reader.reply(
        0,
        null,
        freshness: ReadFreshness.failed,
        error: RpcError(RpcErrorCode.busy, 'read held'),
      );
      await Future<void>(() {});
      expect(model.problem, contains('read held'));
      model.retry();
      _ready(reader, offset: 4);
      await Future<void>(() {});
      expect(model.problem, isNull);
      expect(model.preferencesReady, true);
      await model.dispose();
      final count = updates;
      reader.reply(4, 'true');
      connection.events.add(null);
      await Future<void>(() {});
      expect(updates, count);
      expect(model.complete, false);
      expect(reader.active, 0);
      await _close(reader, connection, model);
    },
  );
}
