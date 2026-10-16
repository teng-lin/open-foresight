import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/note_save_scheduler.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

class GatedNoteDomain extends Domain {
  GatedNoteDomain(super.store, super.helper);
  Completer<void>? saveGate;
  @override
  Future<Object?> command(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'meetings.notes' && saveGate != null) await saveGate!.future;
    return super.command(method, args);
  }
}

void main() {
  testWidgets(
    'failed in-flight save keeps explicit navigation on the editor until retry succeeds',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'note-save-navigation-',
      );
      final store = Store('${directory.path}/app.db');
      store.setPreference('liveEnhance', 'false');
      final id = store.meeting('Unsaved editor');
      store.saveMeetingNotes(id, 'Stored original');
      final domain = GatedNoteDomain(
        store,
        OfflineHelper('${directory.path}/sock', '${directory.path}/helper'),
      );
      await tester.pumpWidget(Foresight(domain, deviceLoader: () async => []));
      final dynamic state = tester.state(find.byType(Workspace));
      state.update(() => state.meetingId = id);
      await tester.pumpAndSettle();
      domain.saveGate = Completer<void>();
      await tester.enterText(
        find.byKey(const ValueKey('meeting-notes-editor')),
        'Unsaved latest',
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byTooltip('All meetings'));
      await tester.pump();
      expect(state.meetingId, id);
      domain.saveGate!.completeError(StateError('Fixture save failed'));
      await tester.pumpAndSettle();
      expect(state.meetingId, id);
      expect(state.error, contains('Unable to save meeting notes'));
      expect(
        store.rows('SELECT body FROM meeting_notes').single['body'],
        'Stored original',
      );
      domain.saveGate = null;
      await tester.tap(find.byTooltip('All meetings'));
      await tester.pumpAndSettle();
      expect(state.meetingId, isNull);
      expect(
        store.rows('SELECT body FROM meeting_notes').single['body'],
        'Unsaved latest',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      directory.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'flush and close observe an in-flight failure and retain its draft for retry',
    (tester) async {
      final pending = Completer<void>();
      var attempts = 0;
      final saves = NoteSaveScheduler((_, _) async {
        attempts++;
        if (attempts == 1) await pending.future;
      }, onError: (_, _) {});
      saves.schedule(1, 'Still unsaved');
      await tester.pump(const Duration(seconds: 1));
      final flushed = expectLater(saves.flush(), throwsStateError);
      final closed = expectLater(saves.close(), throwsStateError);
      pending.completeError(StateError('In-flight write rejected'));
      await tester.pump();
      await flushed;
      await closed;
      expect(saves.hasWork, isTrue);
      await saves.flush();
      expect(attempts, 2);
      expect(saves.hasWork, isFalse);
    },
  );
  testWidgets(
    'failed drafts remain retryable and newer edits supersede failed snapshots',
    (tester) async {
      final writes = <(int, String)>[];
      final failures = <Object>[];
      var reject = true;
      final saves = NoteSaveScheduler((id, body) async {
        writes.add((id, body));
        if (reject) throw StateError('Fixture save rejected');
      }, onError: (error, _) => failures.add(error));
      saves.schedule(1, 'Retry this draft');
      await tester.pump(const Duration(seconds: 1));
      expect(failures, hasLength(1));
      expect(saves.hasWork, isTrue);
      reject = false;
      await saves.flush();
      expect(writes, [(1, 'Retry this draft'), (1, 'Retry this draft')]);
      expect(saves.hasWork, isFalse);
      reject = true;
      saves.schedule(1, 'Old failed draft');
      await tester.pump(const Duration(seconds: 1));
      saves.schedule(1, 'Newer draft');
      reject = false;
      await saves.close();
      expect(writes.last, (1, 'Newer draft'));
      expect(
        writes.where((draft) => draft.$2 == 'Old failed draft'),
        hasLength(1),
      );
    },
  );
  testWidgets(
    'save deadline follows the latest edit and close drains snapshots in order',
    (tester) async {
      final writes = <(int, String)>[];
      final first = Completer<void>();
      final saves = NoteSaveScheduler((id, body) async {
        writes.add((id, body));
        if (id == 1) await first.future;
      });
      saves.schedule(1, 'first');
      await tester.pump(const Duration(milliseconds: 500));
      saves.schedule(1, 'latest');
      await tester.pump(const Duration(milliseconds: 999));
      expect(writes, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(writes, [(1, 'latest')]);
      saves.schedule(2, 'second note');
      var closed = false;
      final closing = saves.close().then((_) => closed = true);
      await tester.pump();
      expect(closed, isFalse);
      first.complete();
      await tester.pump();
      await closing;
      expect(writes, [(1, 'latest'), (2, 'second note')]);
      expect(closed, isTrue);
      saves.schedule(3, 'after disposal');
      await tester.pump(const Duration(seconds: 2));
      expect(writes, hasLength(2));
    },
  );

  testWidgets(
    'note switch flushes captured draft before the new note deadline',
    (tester) async {
      final writes = <(int, String)>[];
      final saves = NoteSaveScheduler(
        (id, body) async => writes.add((id, body)),
      );
      saves.schedule(1, 'old note draft');
      await tester.pump(const Duration(milliseconds: 100));
      saves.schedule(2, 'new note draft');
      await tester.pump();
      expect(writes, [(1, 'old note draft')]);
      await tester.pump(const Duration(milliseconds: 999));
      expect(writes, hasLength(1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(writes, [(1, 'old note draft'), (2, 'new note draft')]);
      await saves.close();
    },
  );

  testWidgets('editor debounces edits and flushes note switch and disposal', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('note-save-editor-');
    final path = '${directory.path}/app.db';
    final store = Store(path);
    store.setPreference('liveEnhance', 'false');
    final first = store.meeting('First');
    final second = store.meeting('Second');
    store.saveMeetingNotes(first, 'Initial');
    final domain = Domain(
      store,
      OfflineHelper('${directory.path}/sock', '${directory.path}/helper'),
    );
    await tester.pumpWidget(Foresight(domain, deviceLoader: () async => []));
    final dynamic state = tester.state(find.byType(Workspace));
    state.update(() => state.meetingId = first);
    await tester.pumpAndSettle();
    final editor = find.byKey(const ValueKey('meeting-notes-editor'));
    await tester.enterText(editor, 'Intermediate');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(editor, 'Latest first');
    await tester.pump(const Duration(milliseconds: 999));
    expect(
      store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
        first,
      ]).single['body'],
      'Initial',
    );
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(
      store.rows('SELECT body,revision FROM meeting_notes WHERE meeting_id=?', [
        first,
      ]).single,
      {'body': 'Latest first', 'revision': 2},
    );
    await tester.enterText(editor, 'Flushed first');
    state.update(() => state.meetingId = second);
    await tester.pumpAndSettle();
    expect(
      store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
        first,
      ]).single['body'],
      'Flushed first',
    );
    expect(
      store.rows('SELECT * FROM meeting_notes WHERE meeting_id=?', [second]),
      isEmpty,
    );
    await tester.enterText(editor, 'Last second keystrokes');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final reopened = Store(path);
    expect(
      reopened.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
        second,
      ]).single['body'],
      'Last second keystrokes',
    );
    reopened.close();
    directory.deleteSync(recursive: true);
  });
}
