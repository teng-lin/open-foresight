import 'package:foresight_test_support/google_connections.dart';
import 'package:open_foresight/shell/workspace_tab.dart';
import '../test_support/core_fixture.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/failure_text.dart';
import 'package:open_foresight/main.dart';

import 'desktop_connection_fixture.dart';
import 'pump_until.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

/// Commits a create, then loses its reply as a dropped connection would.
class LostReplyDomain extends CommandFixtureDomain with TranscriptIndexAdapter {
  LostReplyDomain(super.store, super.helper);
  final lose = <Operation>{};
  final sent = <(Operation, Map<String, dynamic>)>[];

  /// Holds the next reply after its write committed.
  Completer<void>? hold;

  /// Indexing is not under test here; it succeeds without a helper.
  @override
  Future<void> index(String id, {bool Function()? current}) async =>
      store.state(id, 'indexed');
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    sent.add((operation, args));
    final result = await super.command(operation, args);
    final held = hold;
    hold = null;
    await held?.future;
    if (lose.remove(operation)) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'Application service disconnected',
        reason: RpcErrorReason.outcomeUnknown,
      );
    }
    return result;
  }
}

void main() {
  late Store store;
  late LostReplyDomain domain;
  late Application app;
  setUp(() {
    final root = createTestTempDirectorySync('pending-create-');
    store = Store('${root.path}/app.db');
    domain = LostReplyDomain(
      store,
      OfflineHelper('${root.path}/socket', '${root.path}/helper'),
    );
    app = Application(domain);
  });

  Future<WorkspaceTestAccess> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Foresight(TestDesktopConnection(app), deviceLoader: () async => []),
    );
    await tester.pumpAndSettle();
    return tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
  }

  List<Object?> keys(Operation operation) => [
    for (final (sent, args) in domain.sent)
      if (sent == operation) args['idempotency_key'],
  ];

  testWidgets('saving a new note again after a lost reply creates it once', (
    tester,
  ) async {
    final state = await show(tester);
    state.update(() => state.navigate(WorkspaceTab.notes));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Kept once');
    await tester.enterText(fields.at(1), 'Body');
    domain.lose.add(Operation.notesSave);
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    expect(state.error, outcomeUnknownText);
    expect(state.sourceFeature.noteId, isNull);
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    final note = store.rows('SELECT id,title FROM notes').single;
    expect(note['title'], 'Kept once');
    expect(state.sourceFeature.noteId, note['id']);
    final sent = keys(Operation.notesSave);
    expect(sent, hasLength(2));
    expect(sent.toSet(), hasLength(1));
    // The next new note is a different action with its own key.
    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    await tester.enterText(fields.at(0), 'Second');
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    expect(store.rows('SELECT id FROM notes'), hasLength(2));
    expect(keys(Operation.notesSave).toSet(), hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pressing New meeting again after a lost reply creates once', (
    tester,
  ) async {
    final state = await show(tester);
    domain.lose.add(Operation.meetingsCreate);
    await tester.tap(find.text('New meeting'));
    await tester.pumpAndSettle();
    expect(state.error, outcomeUnknownText);
    await tester.tap(find.text('New meeting'));
    await tester.pumpAndSettle();
    final meeting = store.rows('SELECT id FROM meetings').single['id'];
    expect(state.meetingFeature.meetingId, meeting);
    expect(keys(Operation.meetingsCreate).toSet(), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('retrying a new note with edited text saves one note', (
    tester,
  ) async {
    final state = await show(tester);
    state.update(() => state.navigate(WorkspaceTab.notes));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Draft');
    await tester.enterText(fields.at(1), 'First');
    domain.lose.add(Operation.notesSave);
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    expect(state.error, outcomeUnknownText);
    await tester.enterText(fields.at(1), 'Edited');
    await tester.tap(find.text('Save note'));
    await tester.pumpAndSettle();
    final note = store.rows('SELECT id,body FROM notes').single;
    expect(note['body'], 'Edited');
    expect(state.sourceFeature.noteId, note['id']);
    expect(state.error, isEmpty);
    // The key only ever carried the first text; the edit went by ID.
    final saves = [
      for (final (operation, args) in domain.sent)
        if (operation == Operation.notesSave) args,
    ];
    expect(saves.map((args) => args['body']), ['First', 'First', 'Edited']);
    expect(saves[1]['idempotency_key'], saves[0]['idempotency_key']);
    expect(saves[2], isNot(contains('idempotency_key')));
    expect(saves[2]['id'], note['id']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the reply to a new note after a workspace reset is dropped', (
    tester,
  ) async {
    final state = await show(tester);
    state.update(() => state.navigate(WorkspaceTab.notes));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Before the clear');
    final reply = domain.hold = Completer<void>();
    await tester.tap(find.text('Save note'));
    await tester.pump();
    // Another client clears the workspace while the reply is in flight.
    await tester.runAsync(() => app.call(Operation.workspaceClear.wire, {}));
    // The save is still in flight, so wait for the reset, not for settling.
    await pumpUntil(
      tester,
      () => state.d.workspaceEpoch == store.workspaceEpoch,
    );
    final reused = store.saveNote(null, 'After the clear', '');
    reply.complete();
    await tester.pumpAndSettle();
    expect(state.sourceFeature.noteId, isNull, reason: 'note $reused');
    expect(state.sourceFeature.noteTitle.text, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('importing a transcript again after a lost reply appends once', (
    tester,
  ) async {
    final state = await show(tester);
    final id = store.meeting('Imported transcript');
    final directory = createTestTempDirectorySync('transcript-import-');
    final transcript = File('${directory.path}/transcript.txt')
      ..writeAsStringSync('Speaker: What is the deadline?');
    final second = File('${directory.path}/second.txt')
      ..writeAsStringSync('Speaker: Next Friday.');
    var selected = transcript.path;
    const channel = MethodChannel('plugins.flutter.io/file_selector');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => [selected],
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    // As the Import transcript button runs it, with real file reads.
    Future<void> action() => state.meetingFeature.importMeetingTranscript(id);
    Future<void> importChosen() => tester.runAsync(() => state.run(action));
    List<Object?> segments() => [
      for (final row in store.meetingTranscript(id)) row['text'],
    ];
    domain.lose.add(Operation.meetingsTranscript);
    await importChosen();
    await tester.pumpAndSettle();
    expect(state.error, outcomeUnknownText);
    expect(segments(), ['Speaker: What is the deadline?'], reason: 'committed');
    // Choosing the same file again retries that import.
    await importChosen();
    await tester.pumpAndSettle();
    expect(state.error, isEmpty);
    expect(segments(), ['Speaker: What is the deadline?']);
    final sent = keys(Operation.meetingsTranscript);
    expect(sent, hasLength(2));
    expect(sent.toSet(), hasLength(1));
    expect(sent.first, isA<String>());
    // Another file is a new import with its own key.
    selected = second.path;
    await importChosen();
    await tester.pumpAndSettle();
    expect(segments(), [
      'Speaker: What is the deadline?',
      'Speaker: Next Friday.',
    ]);
    expect(keys(Operation.meetingsTranscript).toSet(), hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('opening a meeting starts a new action for New meeting', (
    tester,
  ) async {
    final state = await show(tester);
    domain.lose.add(Operation.meetingsCreate);
    await tester.tap(find.text('New meeting'));
    await tester.pumpAndSettle();
    // The user opens the meeting that may have been created, so a later New
    // meeting is a new action, not a retry that returns this meeting.
    await tester.tap(find.text('[New Meeting]').first);
    await tester.pumpAndSettle();
    expect(state.meetingFeature.meetingPreviewId, isNotNull);
    await tester.tap(find.text('New meeting'));
    await tester.pumpAndSettle();
    expect(store.rows('SELECT id FROM meetings'), hasLength(2));
    expect(keys(Operation.meetingsCreate).toSet(), hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
