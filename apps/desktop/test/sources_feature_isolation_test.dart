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
    expect(query.projection, anyOf('note_body', 'source'));
    final completer = Completer<ReadResult<Object?>>();
    pending.add(completer);
    return completer.future.then((result) => result.asType<T>());
  }

  void complete(int index, Object? body, {RpcError? error}) =>
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
  final writes = <Map<String, dynamic>>[];
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    expect(operation, Operation.notesSave);
    writes.add(Map.of(args));
    return {'id': args['id'] ?? 8};
  }

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

  testWidgets(
    'local source open errors report only to their live owner without holding the operation gate',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              host.context = context;
              return const SizedBox();
            },
          ),
        ),
      );
      controller.showSource('current');
      expect(host.busy, isFalse);
      connection.store.complete(
        0,
        null,
        error: RpcError(RpcErrorCode.unavailable, 'current source failure'),
      );
      await tester.pump();
      expect(host.error, contains('current source failure'));
      host.error = '';
      controller.showSource('retired');
      connection.clientSessionGeneration = Object();
      connection.events.add(null);
      connection.store.complete(
        1,
        null,
        error: RpcError(RpcErrorCode.unavailable, 'retired source failure'),
      );
      await tester.pump();
      expect(host.error, isEmpty);
      controller.showSource('disposed');
      controller.dispose();
      connection.store.complete(
        2,
        null,
        error: RpcError(RpcErrorCode.unavailable, 'disposed source failure'),
      );
      await tester.pump();
      expect(host.error, isEmpty);
      expect(tester.takeException(), isNull);
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
  testWidgets('failed note body never enables a placeholder overwrite', (
    tester,
  ) async {
    final opening = controller.openNote(note(8));
    final failed = expectLater(opening, throwsA(isA<RpcError>()));
    connection.store.complete(
      0,
      null,
      error: RpcError(RpcErrorCode.unavailable, 'body read failed'),
    );
    await failed;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, rebuild) {
            host.context = context;
            host.rebuild = rebuild;
            return Scaffold(body: controller.notes());
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save note');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(connection.writes, isEmpty);
  });
  for (final retry in ['button', 'reselection']) {
    testWidgets('note $retry retains intentional draft after failed load', (
      tester,
    ) async {
      final opening = controller.openNote(note(8));
      controller.noteBody.text = 'Draft before failure';
      final failed = expectLater(opening, throwsA(isA<RpcError>()));
      connection.store.complete(
        0,
        null,
        error: RpcError(RpcErrorCode.unavailable, 'body read failed'),
      );
      await failed;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, rebuild) {
              host.context = context;
              host.rebuild = rebuild;
              return Scaffold(body: controller.notes());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.noteTitle.text = 'Draft title';
      controller.noteBody.text = 'Draft after failure';
      Future<void>? reselected;
      if (retry == 'button') {
        await tester.tap(find.text('Retry loading note'));
      } else {
        reselected = controller.openNote(note(8));
      }
      await tester.pump();
      expect(controller.noteLoading, isTrue);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save note'),
            )
            .onPressed,
        isNull,
      );
      connection.store.complete(1, 'Persisted body');
      if (reselected != null) await reselected;
      await tester.pumpAndSettle();
      expect(controller.noteBodyReady, isFalse);
      expect(connection.writes, isEmpty);
      await tester.tap(find.text('Review saved note'));
      await tester.pumpAndSettle();
      expect(find.text('Persisted body'), findsOneWidget);
      await tester.tap(find.text('Keep my draft'));
      await tester.pumpAndSettle();
      expect(controller.noteBodyReady, isTrue);
      expect(controller.noteBody.text, 'Draft after failure');
      expect(controller.noteTitle.text, 'Draft title');
      expect(controller.noteBaseline, ('Note 8', 'Persisted body'));
      await tester.tap(find.text('Save note'));
      await tester.pumpAndSettle();
      expect(
        connection.writes.single,
        containsPair('body', 'Draft after failure'),
      );
      expect(connection.writes.single, containsPair('id', 8));
    });
  }

  testWidgets(
    'empty accepted body permits saving; New note clears a failed load',
    (tester) async {
      final opening = controller.openNote(note(8));
      final failed = expectLater(opening, throwsA(isA<RpcError>()));
      connection.store.complete(
        0,
        null,
        error: RpcError(RpcErrorCode.unavailable, 'body read failed'),
      );
      await failed;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, rebuild) {
              host.context = context;
              host.rebuild = rebuild;
              return Scaffold(body: controller.notes());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry loading note'));
      await tester.pump();
      connection.store.complete(1, '');
      await tester.pumpAndSettle();
      expect(controller.noteBodyReady, isTrue);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save note'),
            )
            .onPressed,
        isNotNull,
      );
      final another = controller.openNote(note(9));
      final anotherFailed = expectLater(another, throwsA(isA<RpcError>()));
      connection.store.complete(
        2,
        null,
        error: RpcError(RpcErrorCode.unavailable, 'second body failure'),
      );
      await anotherFailed;
      await tester.pumpAndSettle();
      await tester.tap(find.text('New note'));
      await tester.pumpAndSettle();
      expect(controller.noteId, isNull);
      expect(find.text('Retry loading note'), findsNothing);
      controller.noteBody.text = 'New draft';
      await tester.tap(find.text('Save note'));
      await tester.pumpAndSettle();
      expect(connection.writes.single, containsPair('body', 'New draft'));
      expect(connection.writes.single.containsKey('id'), isFalse);
      expect(controller.noteBodyReady, isTrue);
    },
  );

  for (final boundary in ['session', 'epoch']) {
    testWidgets(
      'held note retry cannot authorize saving after $boundary replacement',
      (tester) async {
        final opening = controller.openNote(note(8));
        final failed = expectLater(opening, throwsA(isA<RpcError>()));
        connection.store.complete(
          0,
          null,
          error: RpcError(RpcErrorCode.unavailable, 'body read failed'),
        );
        await failed;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, rebuild) {
                host.context = context;
                host.rebuild = rebuild;
                return Scaffold(body: controller.notes());
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Retry loading note'));
        await tester.pump();
        if (boundary == 'session') {
          connection.clientSessionGeneration = Object();
        } else {
          connection.workspaceEpoch = connection.store.workspaceEpoch =
              'replacement';
        }
        connection.events.add(null);
        connection.store.complete(1, 'Retired body');
        await tester.pumpAndSettle();
        expect(controller.noteBodyReady, isFalse);
        expect(controller.noteBody.text, '');
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Save note'),
              )
              .onPressed,
          isNull,
        );
        expect(connection.writes, isEmpty);
        await tester.tap(find.text('Retry loading note'));
        await tester.pump();
        connection.store.complete(2, 'Current body');
        await tester.pumpAndSettle();
        expect(controller.noteBodyReady, isTrue);
        final save = tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save note'),
            )
            .onPressed!;
        connection.clientSessionGeneration = Object();
        // An already built callback independently checks body ownership.
        save();
        await tester.pumpAndSettle();
        expect(connection.writes, isEmpty);
        controller.dispose();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'retained note retry and save callbacks admit nothing after disposal',
    (tester) async {
      final opening = controller.openNote(note(8));
      final failed = expectLater(opening, throwsA(isA<RpcError>()));
      connection.store.complete(
        0,
        null,
        error: RpcError(RpcErrorCode.unavailable, 'body read failed'),
      );
      await failed;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, rebuild) {
              host.context = context;
              host.rebuild = rebuild;
              return Scaffold(body: controller.notes());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final retry = tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Retry loading note'),
          )
          .onPressed!;
      await tester.tap(find.text('New note'));
      await tester.pumpAndSettle();
      final save = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save note'))
          .onPressed!;
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
      retry();
      save();
      await tester.pump();
      expect(connection.store.pending, hasLength(1));
      expect(connection.writes, isEmpty);
    },
  );
  testWidgets(
    'slow successful note load shows its saved body before any replacement',
    (tester) async {
      final opening = controller.openNote(note(8));
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, rebuild) {
              host.context = context;
              host.rebuild = rebuild;
              return Scaffold(body: controller.notes());
            },
          ),
        ),
      );
      await tester.pump();
      final title = find.widgetWithText(TextField, 'Title');
      final body = find.widgetWithText(TextField, 'Your editable note');
      final titleWasReadOnly = tester.widget<TextField>(title).readOnly;
      final bodyWasReadOnly = tester.widget<TextField>(body).readOnly;
      await tester.tap(body);
      if (tester.testTextInput.hasAnyClients) {
        tester.testTextInput.enterText('x');
        await tester.pump();
      }
      connection.store.complete(0, 'Previously saved body');
      await opening;
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save note'));
      await tester.pumpAndSettle();
      expect(connection.writes.single['body'], 'Previously saved body');
      expect(titleWasReadOnly, isTrue);
      expect(bodyWasReadOnly, isTrue);
      expect(tester.widget<TextField>(body).readOnly, isFalse);
    },
  );
  test(
    'selection-only controller notifications do not hide a loaded body',
    () async {
      final opening = controller.openNote(note(8));
      controller.noteBody.selection = const TextSelection.collapsed(offset: 0);
      connection.store.complete(0, 'Saved body after selection');
      await opening;
      expect(controller.noteBody.text, 'Saved body after selection');
      expect(controller.noteBodyReady, isTrue);
    },
  );

  for (final boundary in ['use saved', 'session', 'selection', 'disposal']) {
    testWidgets('diverged draft review respects $boundary', (tester) async {
      final opening = controller.openNote(note(8));
      controller.noteBody.text = 'Retained draft';
      connection.store.complete(0, 'Saved body to review');
      await opening;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, rebuild) {
              host.context = context;
              host.rebuild = rebuild;
              return Scaffold(body: controller.notes());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.noteBodyReady, isFalse);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save note'),
            )
            .onPressed,
        isNull,
      );
      final review = tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Review saved note'),
          )
          .onPressed!;
      review();
      await tester.pumpAndSettle();
      expect(find.text('Saved body to review'), findsOneWidget);
      if (boundary == 'session') {
        connection.clientSessionGeneration = Object();
      } else if (boundary == 'selection') {
        final selecting = controller.openNote(note(9));
        connection.store.complete(1, 'Another note body');
        await selecting;
      } else if (boundary == 'disposal') {
        host.mounted = false;
      }
      await tester.tap(
        find.text(boundary == 'use saved' ? 'Use saved note' : 'Keep my draft'),
      );
      await tester.pumpAndSettle();
      expect(connection.writes, isEmpty);
      if (boundary == 'use saved') {
        expect(controller.noteBody.text, 'Saved body to review');
        expect(controller.noteBodyReady, isTrue);
      } else if (boundary == 'selection') {
        expect(controller.noteBody.text, 'Another note body');
        expect(controller.noteId, 9);
        expect(controller.noteBodyReady, isTrue);
        review();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      } else {
        expect(controller.noteBody.text, 'Retained draft');
        expect(controller.noteBodyReady, isFalse);
      }
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
    });
  }
}
