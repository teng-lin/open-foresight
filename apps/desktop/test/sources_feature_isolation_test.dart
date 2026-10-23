import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/desktop_environment.dart';
import 'package:open_foresight/features/sources/sources_controller.dart';
import 'package:open_foresight/shell/ports.dart';
import 'package:open_foresight/shell/workspace_tab.dart';

class _Reader implements StoreReader {
  int watches = 0;
  final pending = <Completer<ReadResult<Object?>>>[];
  @override
  String workspaceEpoch = 'workspace';
  @override
  String dataRevision = '1';
  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    watches++;
    final Object? value = switch (query.projection) {
      'sources' => <SourceSummary>[
        SourceSummary.fromRow({
          'id': 'source',
          'title': 'Fixture source',
          'state': 'indexed',
          'mime': 'text/plain',
        }),
      ],
      'notes' => <NoteSummary>[],
      'source_mimes' => <String, String>{},
      'labels' => <DocumentLabel>[],
      'clusters' => <DocumentCluster>[],
      'cluster_names' => <String>[],
      'graph_label_set' => '',
      'model' => null,
      _ => throw StateError('Unexpected watch ${query.projection}'),
    };
    return Stream.value(
      ReadResult<T>(
        freshness: ReadFreshness.current,
        value: value as T,
        requestTag: 'fixture',
        sequence: 0,
      ),
    );
  }

  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) {
    expect(query.projection, 'note_body');
    final completer = Completer<ReadResult<Object?>>();
    pending.add(completer);
    return completer.future.then((result) => result.asType<T>());
  }

  void complete(int index, String body, {RpcError? error}) =>
      pending[index].complete(
        ReadResult<Object?>(
          freshness: ReadFreshness.current,
          value: body,
          error: error,
          requestTag: 'note',
          sequence: index,
        ),
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected synchronous projection ${invocation.memberName}',
  );
}

class _Connection implements DesktopConnection {
  @override
  final _Reader store = _Reader();
  @override
  String? workspaceEpoch = 'workspace';
  @override
  Object clientSessionGeneration = Object();
  // Closed by the fixture after the feature retires.
  // ignore: close_sinks
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  @override
  bool get sourcesPaused => false;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected connection access ${invocation.memberName}');
}

class _Host
    implements
        FeatureHost,
        WorkspaceNavigation,
        OperationGate,
        WorkspaceDialogs {
  _Host(this.connection);
  @override
  final _Connection connection;
  @override
  late BuildContext context;
  @override
  bool mounted = true;
  @override
  final environment = const DesktopEnvironment();
  @override
  final ValueNotifier<int> serviceUiRevision = ValueNotifier<int>(0);
  @override
  final ValueNotifier<List<double>> captureVolumes =
      ValueNotifier<List<double>>(const []);
  @override
  final vsync = TestVSync();
  @override
  WorkspaceTab selectedTab = WorkspaceTab.sources;
  @override
  bool busy = false;
  @override
  String error = '';
  StateSetter rebuild = (action) => action();
  @override
  void update(VoidCallback action) => rebuild(action);
  @override
  void navigate(WorkspaceTab destination) => selectedTab = destination;
  @override
  void setError(String value) => error = value;
  @override
  void reportAsyncError(Object failure) => error = '$failure';
  @override
  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (failure) {
      reportAsyncError(failure);
    }
  }

  @override
  bool rowsAreCurrent() => true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected host access ${invocation.memberName}');
}

class _Integrations implements IntegrationsPort {
  @override
  GooglePresentation get googlePresentation =>
      GooglePresentation.fromWire(const {});
  @override
  bool get driveAvailable => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected integration access ${invocation.memberName}',
  );
}

void main() {
  late _Connection connection;
  late _Host host;
  late SourcesController controller;
  setUp(() {
    connection = _Connection();
    host = _Host(connection);
    controller = SourcesController(
      host: host,
      navigation: host,
      operations: host,
      dialogs: host,
      integrations: _Integrations(),
    );
    controller.initializeGraph();
  });
  tearDown(() async {
    controller.dispose();
    await connection.events.close();
    host.serviceUiRevision.dispose();
    host.captureVolumes.dispose();
  });
  NoteSummary note(int id) =>
      NoteSummary.fromRow({'id': id, 'title': 'Note $id', 'revision': 1});

  testWidgets(
    'Sources mounts with narrow ports and rebuilds without persistence admissions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, rebuild) {
              host.context = context;
              host.rebuild = rebuild;
              return Scaffold(body: SourcesView(controller));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fixture source'), findsOneWidget);
      expect(connection.store.watches, 8);
      host.update(() {});
      connection.store.dataRevision = '2';
      connection.events.add(null);
      await tester.pumpAndSettle();
      expect(connection.store.watches, 8);
      await tester.tap(find.byTooltip('Grid view'));
      await tester.pumpAndSettle();
      expect(find.text('Fixture source'), findsOneWidget);
      expect(connection.store.watches, 8);
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );

  test(
    'held note body preserves a typed draft and records the persisted baseline',
    () async {
      final opening = controller.openNote(note(1));
      expect(controller.noteLoading, isTrue);
      controller.noteBody.text = 'typed while loading';
      connection.store.complete(0, 'persisted');
      await opening;
      expect(controller.noteBody.text, 'typed while loading');
      expect(controller.noteBaseline, ('Note 1', 'persisted'));
      expect(controller.noteLoading, isFalse);
    },
  );

  test(
    'note replacement and owner retirement suppress stale body and failures',
    () async {
      final first = controller.openNote(note(1));
      final second = controller.openNote(note(2));
      connection.store.complete(0, 'stale');
      await first;
      expect(controller.noteLoading, isTrue);
      expect(controller.noteId, 2);
      expect(controller.noteBody.text, '');
      connection.store.complete(1, 'current');
      await second;
      expect(controller.noteBody.text, 'current');
      final retired = controller.openNote(note(3));
      connection.clientSessionGeneration = Object();
      connection.store.complete(
        2,
        '',
        error: RpcError(RpcErrorCode.unavailable, 'retired failure'),
      );
      await retired;
      expect(controller.noteBody.text, '');
      final current = controller.openNote(note(4));
      connection.store.complete(
        3,
        '',
        error: RpcError(RpcErrorCode.unavailable, 'current failure'),
      );
      await expectLater(current, throwsA(isA<RpcError>()));
      expect(controller.noteLoading, isFalse);
      expect(controller.noteBody.text, '');
      final disposed = controller.openNote(note(5));
      controller.dispose();
      connection.store.complete(4, 'after dispose');
      await disposed;
    },
  );
}
