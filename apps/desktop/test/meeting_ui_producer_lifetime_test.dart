import 'package:foresight_test_support/google_connections.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/generated_content.dart';
import 'package:open_foresight/main.dart';
import '../test_support/meeting_panel.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class _ReadyUiHelper extends OfflineHelper {
  _ReadyUiHelper(super.socket, super.storage);
  @override
  Future<void> start() async {
    await super.start();
    await onReady?.call();
  }
}

Future<void> _pumpUiUntil(WidgetTester tester, bool Function() ready) async {
  final elapsed = Stopwatch()..start();
  while (!ready() && elapsed.elapsed < const Duration(seconds: 5)) {
    // Real workflow loops yield with Duration.zero. UI-launched work runs in
    // the widget's fake-clock zone, so explicitly run its timers as well as I/O.
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() => Future<void>(() {}));
  }
  expect(
    ready(),
    isTrue,
    reason: 'Expected UI workflow event within 5 seconds',
  );
  await tester.pump();
}

class _HeldUiProducer extends NativeRuntime {
  _HeldUiProducer(this.kind, {required this.fail})
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final String kind;
  final bool fail;
  final entered = Completer<void>(), release = Completer<void>();
  final settled = Completer<void>();
  int cancellations = 0;
  String get preview => 'HELD ORIGINAL $kind PREVIEW';
  String get result => 'LATE ORIGINAL $kind RESULT';
  String get error => 'LATE ORIGINAL $kind ERROR';
  @override
  bool get generating => false;
  @override
  Map<String, dynamic> get effectiveState => {'state': 'ready'};
  @override
  Stream<Map<String, dynamic>> generateSummary(
    String id,
    String prompt, {
    required String systemPrompt,
    int maxOutputTokens = 1024,
  }) async* {
    // Preparation document-map previews are intentionally not rendered. Finish
    // two real maps, then hold synthesis where the UI actually has a preview.
    if (kind == 'preparation' && !prompt.contains('Meeting context:')) {
      yield {'type': 'delta', 'text': 'Verified local document evidence.'};
      yield {'type': 'done', 'status': 'completed'};
      return;
    }
    try {
      entered.complete();
      yield {'type': 'preview', 'text': '# Overview\n$preview'};
      await release.future;
      if (fail) {
        yield {'type': 'error', 'message': error};
        yield {'type': 'done', 'status': 'failed'};
        return;
      }
      var body = '# Overview\n$result';
      if (kind == 'actions') {
        final evidence =
            ((jsonDecode(prompt) as Map)['evidence'] as List).first as Map;
        body = jsonEncode({
          'tasks': [
            {
              'task': result,
              'owner': 'Alice',
              'due': 'Friday',
              'state': 'open',
              'evidence': [
                {'id': evidence['id'], 'quote': 'Alice will ship Friday.'},
              ],
            },
          ],
        });
      }
      yield {'type': 'delta', 'text': body};
      yield {'type': 'done', 'status': 'completed'};
    } finally {
      settled.complete();
    }
  }

  @override
  bool cancel({String? requestId}) {
    cancellations++;
    // Ignore cancellation until the gate opens. UI cancellation/close must not
    // stand in for actual producer and authoritative command settlement.
    return true;
  }

  @override
  void close() {}
}

class _UiDomain extends AdapterDomain {
  _UiDomain(super.store, super.helper);
  @override
  Future<void> index(String id, {bool Function()? current}) async {
    if (current?.call() ?? true) store.state(id, 'indexed');
  }
}

class _UiConnection extends TestDesktopConnection {
  _UiConnection(super.application, this.kind);
  final String kind;
  @override
  Future<void> resume() async {
    // Model discovery is outside this fixture; install the controlled producer
    // only after startup, just as the existing ControllerConnection does.
  }

  bool commandEntered = false, commandSettled = false;
  Object? commandFailure;
  bool _generation(Operation operation, Map<String, dynamic> args) =>
      operation == Operation.meetingsPrepare ||
      (operation == Operation.meetingsGenerate && args['kind'] == kind);
  Future<Object?> _observe(
    Operation operation,
    Map<String, dynamic> args,
    Future<Object?> Function() invoke,
  ) async {
    if (!_generation(operation, args)) return invoke();
    commandEntered = true;
    try {
      return await invoke();
    } catch (error) {
      commandFailure = error;
      rethrow;
    } finally {
      commandSettled = true;
    }
  }

  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) => _observe(operation, args, () => super.command(operation, args));

  @override
  Future<Object?> commandCurrent(
    Operation operation,
    Map<String, dynamic> args,
    bool Function() current,
  ) async {
    if (!current()) throw RpcError(RpcErrorCode.cancelled, 'Retired UI action');
    // Unlike TestDesktopConnection's convenience implementation, do not lend a
    // live UI predicate to the authoritative in-process service. A remote RPC
    // already admitted by the service may legitimately commit after reconnect.
    // Only reply delivery is retired; real Application work still settles.
    final result = await _observe(
      operation,
      args,
      () => super.command(operation, args),
    );
    if (!current()) throw RpcError(RpcErrorCode.cancelled, 'Retired UI reply');
    return result;
  }
}

Future<void> _openMeeting(WidgetTester tester, String title) async {
  await _pumpUiUntil(tester, () => find.text(title).evaluate().isNotEmpty);
  await tester.tap(find.text(title).first);
  await tester.pump();
  await tester.tap(find.byTooltip('Expand meeting'));
  await tester.pump();
  await _pumpUiUntil(
    tester,
    () => find.byTooltip('All meetings').evaluate().isNotEmpty,
  );
}

Finder _generated(String text) => find.byWidgetPredicate(
  (widget) => widget is GeneratedContent && widget.markdown.contains(text),
);

Finder _globalErrors(Color color) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is Material && widget.color == color,
  ),
  matching: find.byType(SelectableText),
);

void _seedAccepted(Store store, int meeting, String kind, String owner) {
  store.artifact(meeting, kind, 'ACCEPTED $owner $kind', 'fixture');
  if (kind == 'actions') {
    store.db.execute(
      "INSERT INTO meeting_tasks(meeting_id,task_key,task,owner,due,status,evidence,input_revision,manual) VALUES(?,'manual',?,'Manual owner','Friday','completed','[]',1,1)",
      [meeting, 'Manual $owner task'],
    );
  }
}

void _expectManual(Store store, int meeting, String owner) {
  expect(
    store.rows(
      'SELECT task,owner,due,status,manual FROM meeting_tasks WHERE meeting_id=? AND task_key=?',
      [meeting, 'manual'],
    ).single,
    {
      'task': 'Manual $owner task',
      'owner': 'Manual owner',
      'due': 'Friday',
      'status': 'completed',
      'manual': 1,
    },
  );
}

Future<void> _exerciseUiProducer(
  WidgetTester tester,
  String kind,
  String boundary, {
  required bool fail,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final root = createTestTempDirectorySync('meeting-ui-producer-');
  final path = '${root.path}/app.db';
  final store = Store(path);
  final original = store.meeting('Original UI meeting');
  final other = store.meeting('Other UI meeting');
  store.transcript(
    original,
    'Alice will ship Friday.',
    true,
    0,
    1,
    'microphone',
  );
  _seedAccepted(store, original, kind, 'ORIGINAL');
  _seedAccepted(store, other, kind, 'OTHER');
  for (final name in ['First', 'Second']) {
    store.importText(
      '$name preparation document',
      'Existing local agenda and preparation evidence. ' * 8,
      'text/plain',
      'fixture',
    );
  }
  final helper = _ReadyUiHelper('${root.path}/socket', '${root.path}/helper');
  final domain = _UiDomain(store, helper);
  final connection = _UiConnection(Application(domain), kind);
  final runtime = _HeldUiProducer(kind, fail: fail);
  addTearDown(() async {
    // A failed assertion must release the real producer before the next case.
    if (!runtime.release.isCompleted) runtime.release.complete();
    await tester.pumpWidget(const SizedBox.shrink());
    connection.close();
    var cleaned = false;
    unawaited(connection.closed.then<void>((_) => cleaned = true));
    await _pumpUiUntil(tester, () => cleaned);
  });
  await tester.pumpWidget(Foresight(connection, deviceLoader: () async => []));
  await tester.pumpAndSettle();
  final errorColor = Theme.of(
    tester.element(find.byType(Workspace)),
  ).colorScheme.errorContainer;
  await _openMeeting(tester, 'Original UI meeting');
  await tester.pumpAndSettle();
  await selectMeetingPanel(
    tester,
    {
      'summary': 'Summary',
      'actions': 'Action items',
      'preparation': 'Preparation',
    }[kind]!,
  );
  domain.generator = runtime;
  // Every request starts through the real rendered control and real Application
  // coordinator, not a direct Application.generate* call or a fake capture map.
  await tester.tap(
    find.byTooltip(switch (kind) {
      'summary' => 'Generate Summary',
      'actions' => 'Generate Action items',
      _ => 'Prepare from local documents',
    }),
  );
  if (kind == 'preparation') {
    await tester.pump(const Duration(milliseconds: 400));
    for (final name in ['First', 'Second']) {
      await tester.tap(
        find.widgetWithText(CheckboxListTile, '$name preparation document'),
      );
      await tester.pump();
    }
    await tester.tap(find.text('Use selected documents'));
  }
  await _pumpUiUntil(tester, () => runtime.entered.isCompleted);
  await tester.pump(const Duration(milliseconds: 100));
  expect(connection.commandEntered, isTrue);
  expect(connection.commandSettled, isFalse);
  expect(runtime.settled.isCompleted, isFalse);
  if (kind == 'actions') {
    expect(find.textContaining('Extracting commitments'), findsOneWidget);
    expect(find.text('Manual ORIGINAL task'), findsOneWidget);
    expect(find.text('Your edits are preserved'), findsOneWidget);
  } else {
    await _pumpUiUntil(
      tester,
      () => _generated(runtime.preview).evaluate().isNotEmpty,
    );
    expect(_generated(runtime.preview), findsOneWidget);
  }
  var closed = false;
  if (boundary == 'selection') {
    await tester.tap(find.byTooltip('All meetings'));
    await tester.pump();
    await _openMeeting(tester, 'Other UI meeting');
  } else if (boundary == 'clear') {
    await tester.runAsync(
      () => connection.application.call(Operation.workspaceClear.wire, {}),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final replacement = store.meeting('Replacement UI meeting');
    expect(replacement, original);
    _seedAccepted(store, replacement, kind, 'REPLACEMENT');
    helper.changed?.call();
    await tester.pump(const Duration(milliseconds: 100));
    await _openMeeting(tester, 'Replacement UI meeting');
  } else if (boundary == 'session') {
    final epoch = connection.workspaceEpoch;
    final session = connection.clientSessionGeneration;
    connection.replaceClientSessionForTesting();
    expect(connection.workspaceEpoch, epoch);
    expect(connection.clientSessionGeneration, isNot(same(session)));
  } else if (boundary == 'dispose') {
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(connection.closed.then<void>((_) => closed = true));
  }
  await tester.pump(const Duration(milliseconds: 100));
  expect(connection.commandSettled, isFalse);
  expect(runtime.settled.isCompleted, isFalse);
  if (boundary == 'clear' || boundary == 'dispose') {
    expect(runtime.cancellations, greaterThan(0));
    if (boundary == 'dispose') expect(closed, isFalse);
  }
  if (boundary == 'selection' || boundary == 'clear') {
    final owner = boundary == 'clear' ? 'REPLACEMENT' : 'OTHER';
    expect(_generated(runtime.preview), findsNothing);
    expect(_generated(runtime.result), findsNothing);
    if (kind == 'actions') {
      expect(find.text('Manual $owner task'), findsOneWidget);
    } else {
      expect(_generated('ACCEPTED $owner $kind'), findsOneWidget);
    }
  }
  runtime.release.complete();
  await _pumpUiUntil(
    tester,
    () => runtime.settled.isCompleted && connection.commandSettled,
  );
  if (boundary != 'dispose') {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    if (boundary == 'selection' || boundary == 'clear') {
      final owner = boundary == 'clear' ? 'REPLACEMENT' : 'OTHER';
      expect(_generated(runtime.preview), findsNothing);
      expect(_generated(runtime.result), findsNothing);
      expect(
        find.textContaining(runtime.error, findRichText: true),
        findsNothing,
      );
      if (kind == 'actions') {
        expect(find.text('Manual $owner task'), findsOneWidget);
      } else {
        expect(_generated('ACCEPTED $owner $kind'), findsOneWidget);
      }
    } else if (!fail) {
      // Same-epoch reconnect preserves the authoritative service's legitimate
      // accepted output. Rejecting its persisted data would be a false contract.
      if (kind == 'actions') {
        expect(find.text(runtime.result), findsOneWidget);
      } else {
        expect(_generated(runtime.result), findsOneWidget);
      }
    }
    if (fail && boundary == 'current') {
      expect(_globalErrors(errorColor), findsOneWidget);
      expect(
        find.textContaining(runtime.error, findRichText: true),
        findsWidgets,
      );
    } else {
      expect(_globalErrors(errorColor), findsNothing);
      // A service-owned workflow error for the still-selected meeting may be
      // legitimate after reconnect. Only its retired UI callback must not write
      // a new global error. Another selected/workspace panel cannot show it.
    }
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(connection.closed.then<void>((_) => closed = true));
  }
  await _pumpUiUntil(tester, () => closed);
  final reopened = Store(path);
  try {
    final owner = boundary == 'clear' ? 'REPLACEMENT' : 'ORIGINAL';
    final artifacts = reopened.meetingArtifacts(original, kind);
    expect(
      artifacts.any((row) => row['generated'] == 'ACCEPTED $owner $kind'),
      isTrue,
      reason: 'Accepted history is retained independently of late UI callbacks',
    );
    if (kind == 'actions') _expectManual(reopened, original, owner);
    if (!fail && ['selection', 'session', 'current'].contains(boundary)) {
      expect(
        artifacts.any(
          (row) => (row['generated'] as String).contains(runtime.result),
        ),
        isTrue,
        reason: 'An admitted authoritative service job may still finish',
      );
    } else {
      expect(artifacts, hasLength(1));
    }
  } finally {
    reopened.close();
  }
  expect(tester.takeException(), isNull);
}

void main() {
  for (final boundary in ['clear', 'session']) {
    testWidgets('a retained Summary launch cannot cross $boundary', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final root = createTestTempDirectorySync('summary-queued-launch-');
      final store = Store('${root.path}/app.db');
      final original = store.meeting('Original Summary owner');
      store.transcript(
        original,
        'Alice will ship Friday.',
        true,
        0,
        1,
        'microphone',
      );
      final helper = _ReadyUiHelper('${root.path}/sock', '${root.path}/helper');
      final domain = _UiDomain(store, helper);
      final connection = _UiConnection(Application(domain), 'summary');
      final runtime = _HeldUiProducer('summary', fail: false);
      addTearDown(() async {
        if (!runtime.release.isCompleted) runtime.release.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        connection.close();
        var closed = false;
        unawaited(connection.closed.then<void>((_) => closed = true));
        await _pumpUiUntil(tester, () => closed);
      });
      await tester.pumpWidget(
        Foresight(connection, deviceLoader: () async => []),
      );
      await tester.pumpAndSettle();
      await _openMeeting(tester, 'Original Summary owner');
      await tester.pumpAndSettle();
      await selectMeetingPanel(tester, 'Summary');
      final launch = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Generate Summary',
            ),
          )
          .onPressed!;
      domain.generator = runtime;
      if (boundary == 'clear') {
        await tester.runAsync(
          () => connection.application.call(Operation.workspaceClear.wire, {}),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(store.meeting('Replacement Summary owner'), original);
        store.transcript(
          original,
          'Replacement transcript.',
          true,
          0,
          1,
          'microphone',
        );
        helper.changed?.call();
        await tester.pump(const Duration(milliseconds: 100));
        await _openMeeting(tester, 'Replacement Summary owner');
      } else {
        final epoch = connection.workspaceEpoch;
        connection.replaceClientSessionForTesting();
        expect(connection.workspaceEpoch, epoch);
      }
      launch();
      // Admission happens synchronously inside this actual rendered callback.
      // Do not hide an admitted request by cancelling or editing its arguments.
      expect(connection.commandEntered, isFalse);
      expect(runtime.entered.isCompleted, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
  for (final kind in ['summary', 'actions', 'preparation']) {
    for (final boundary in ['selection', 'clear', 'session', 'dispose']) {
      testWidgets(
        'rendered $kind launch owns held producer across $boundary',
        (tester) => _exerciseUiProducer(tester, kind, boundary, fail: false),
      );
    }
    for (final boundary in ['selection', 'session', 'current']) {
      testWidgets(
        'rendered $kind late error respects $boundary ownership',
        (tester) => _exerciseUiProducer(tester, kind, boundary, fail: true),
      );
    }
  }
}
