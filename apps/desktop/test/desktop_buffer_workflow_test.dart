import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/remote.dart';
import 'package:open_foresight/google_auth.dart';
import 'package:open_foresight/meeting_export.dart';
import 'package:open_foresight/generated/helper_control.pb.dart' as control;
import 'controller_fixture.dart';
import 'pump_until.dart';

class SettingsAccount extends GoogleAuth {
  SettingsAccount(super.directory);
  bool signedIn = true, pending = false;
  int disconnects = 0, cancellations = 0;
  @override
  bool get connected => signedIn;
  @override
  String get email => 'fixture@example.test';
  @override
  bool get signingIn => pending;
  @override
  Future<void> disconnect() async {
    disconnects++;
    signedIn = false;
  }

  @override
  void cancelSignIn() {
    cancellations++;
    pending = false;
  }
}

class SettingsSources implements ConnectedSources {
  int refreshes = 0, calendars = 0, lastYearImports = 0;
  Completer<void>? gate;
  @override
  int get lastCompletedRefreshMs => DateTime.now().millisecondsSinceEpoch;
  @override
  Future<void> refresh() async {
    refreshes++;
    await gate?.future;
  }

  @override
  Future<void> syncCalendar({
    String calendarId = 'primary',
    DateTime? now,
  }) async {
    calendars++;
  }

  @override
  Future<void> importLastYear() async {
    lastYearImports++;
  }

  @override
  List<Map<String, dynamic>> attachments(int meeting) => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'graph embedding failure preserves documents and paused indexing does not start another request',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final ids = [
        for (final name in ['Alpha', 'Beta'])
          f.store.importText(
            name,
            '$name evidence',
            'text/plain',
            'fixture:$name',
          ),
      ];
      for (final id in ids) {
        f.store.state(id, 'indexed');
      }
      f.connection.helper.snapshot = control.State(
        pipeline: 'ready',
        instanceId: 'fixture',
        model: control.ModelIdentity(
          modelDigest: 'fixture',
          tokenizerDigest: 'fixture',
          preprocessing: 'fixture',
          backend: 'fixture',
          dimensions: 3,
        ),
      );
      f.connection.graphFailure = StateError('Embedding worker disconnected');
      f.shell.update(() {
        f.shell.tab = 0;
        f.shell.sourceFeature.graphView = true;
      });
      await tester.pump();
      await pumpUntil(
        tester,
        () => f.shell.sourceFeature.graphLayoutError.toString().isNotEmpty,
      );
      expect(f.shell.sourceFeature.graphOrganizing, false);
      expect(find.text('Graph layout unavailable'), findsOneWidget);
      expect(
        f.shell.sourceFeature.graphLayoutError,
        contains('Embedding worker disconnected'),
      );
      expect(f.connection.graphRequests.single, unorderedEquals(ids));
      expect(f.store.sources, hasLength(2));
      expect(f.shell.sourceFeature.graphSceneVectors, isEmpty);
      f.connection.pauseSources();
      f.shell.update(() {});
      await tester.pump();
      expect(f.shell.sourceFeature.graphLayoutKey, isEmpty);
      expect(f.connection.graphRequests, hasLength(1));
      expect(
        f.store.sources.map((row) => row['content']),
        unorderedEquals(['Alpha evidence', 'Beta evidence']),
      );
    },
  );
  testWidgets(
    'graph embeddings for many sources arrive in bounded batches that survive a failure',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      f.store.db.execute('BEGIN');
      final ids = [
        for (var i = 0; i < 1500; i++)
          f.store.importText(
            'Source $i',
            'Evidence $i',
            'text/plain',
            'fixture:$i',
          ),
      ];
      for (final id in ids) {
        f.store.state(id, 'indexed');
      }
      f.store.db.execute('COMMIT');
      f.connection.helper.snapshot = control.State(
        pipeline: 'ready',
        instanceId: 'fixture',
        model: control.ModelIdentity(
          modelDigest: 'fixture',
          tokenizerDigest: 'fixture',
          preprocessing: 'fixture',
          backend: 'fixture',
          dimensions: 3,
        ),
      );
      // Stand in for the service's reply cap at real embedding sizes. Answer
      // each batch, then fail the one that completes the set.
      var requested = 0;
      f.connection.graphReply = (sources) async {
        requested += sources.length;
        if (sources.length > 128) {
          throw StateError('Reply exceeds 16 MiB; request fewer items.');
        }
        if (requested == ids.length) {
          throw StateError('Embedding worker disconnected');
        }
        return {
          for (final source in sources) source['id'] as String: [1.0, 0, 0],
        };
      };
      f.shell.update(() {
        f.shell.tab = 0;
        f.shell.sourceFeature.graphView = true;
      });
      await tester.pump();
      await pumpUntil(
        tester,
        () => f.shell.sourceFeature.graphLayoutError.toString().isNotEmpty,
      );
      final requests = f.connection.graphRequests;
      expect(
        requests.map((batch) => batch.length),
        everyElement(lessThanOrEqualTo(128)),
      );
      expect(requests, hasLength(greaterThanOrEqualTo(12)));
      expect(requests.expand((batch) => batch), unorderedEquals(ids));
      expect(
        f.shell.sourceFeature.graphLayoutError,
        contains('Embedding worker disconnected'),
      );
      // Earlier batches stay cached, so a later layout requests only the rest.
      expect(
        f.shell.sourceFeature.graphVectorCache,
        hasLength(ids.length - requests.last.length),
      );
    },
  );
  testWidgets(
    'custom export dates stay ordered when either boundary crosses the other and cancelled edits do not apply',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final opened = showDialog<void>(
        context: tester.element(find.byType(Scaffold).first),
        builder: (_) => MeetingExportDialog(
          store: f.store,
          now: DateTime(2026, 10, 16),
          save: (_) async => false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Date range: Last 7 days'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byType(DropdownButtonFormField<MeetingExportPeriod>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom').last);
      await tester.pumpAndSettle();
      Future<void> date(String boundary, String? value) async {
        await tester.tap(find.textContaining('$boundary date:'));
        await tester.pumpAndSettle();
        if (value != null) {
          await tester.tap(
            find.descendant(
              of: find.byType(DatePickerDialog),
              matching: find.byIcon(Icons.edit_outlined),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.descendant(
              of: find.byType(DatePickerDialog),
              matching: find.byType(TextField),
            ),
            value,
          );
          await tester.tap(find.text('OK'));
        } else {
          await tester.tap(find.text('Cancel').last);
        }
        await tester.pumpAndSettle();
      }

      await date('Start', '10/20/2026');
      var labels = tester
          .widgetList<Text>(find.textContaining('date:'))
          .map((text) => text.data!)
          .toList();
      expect(labels[0].split(': ').last, labels[1].split(': ').last);
      expect(labels, ['Start date: 10/20/2026', 'End date: 10/20/2026']);
      await date('End', '10/10/2026');
      labels = tester
          .widgetList<Text>(find.textContaining('date:'))
          .map((text) => text.data!)
          .toList();
      expect(labels[0].split(': ').last, labels[1].split(': ').last);
      expect(labels, ['Start date: 10/10/2026', 'End date: 10/10/2026']);
      final before = List.of(labels);
      await date('Start', null);
      labels = tester
          .widgetList<Text>(find.textContaining('date:'))
          .map((text) => text.data!)
          .toList();
      expect(labels, before);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('Date range: Custom'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await opened;
    },
  );
  testWidgets(
    'answer font controls and dismissal affect presentation without deleting saved answers',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      f.store.answer(
        'Saved question',
        'Saved answer body',
        'completed',
        [],
        'fixture',
        conversation: 'desktop',
      );
      final id = f.store.db.lastInsertRowId;
      f.shell.update(() => f.shell.tab = 1);
      await tester.pumpAndSettle();
      expect(
        find.text('Saved answer body', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.text('A−'));
      await tester.pumpAndSettle();
      expect(f.shell.chatFeature.answerFontSize, 15);
      await tester.tap(find.text('A+'));
      await tester.pumpAndSettle();
      expect(f.shell.chatFeature.answerFontSize, 16);
      await tester.tap(find.byTooltip('Close answer'));
      await tester.pumpAndSettle();
      expect(find.text('Saved answer body', findRichText: true), findsNothing);
      expect(f.shell.chatFeature.hiddenAnswers, contains(id));
      expect(
        f.store.rows('SELECT body FROM answers WHERE id=?', [
          id,
        ]).single['body'],
        'Saved answer body',
      );
    },
  );

  testWidgets(
    'manual transcript questions route answers to their owning meeting',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final id = f.store.meeting('Manual question fixture');
      final other = f.store.meeting('Other meeting');
      f.store.transcript(
        id,
        'Who owns the review?',
        true,
        0,
        1000,
        'microphone',
      );
      f.store.transcript(
        other,
        'Other meeting question?',
        true,
        0,
        1000,
        'microphone',
      );
      final requests = <(String, String, int?)>[];
      f.connection.answerStream = (question, scope, meeting) {
        requests.add((question, scope, meeting));
        return Stream.value('Fixture response for this meeting');
      };
      f.shell.update(() {
        f.shell.meetingFeature.meetingId = id;
        f.shell.meetingFeature.meetingPanel = 'Live Q&A';
      });
      await tester.pumpAndSettle();
      expect(find.text('Other meeting question?'), findsNothing);
      await tester.tap(find.byTooltip('Answer this question'));
      await tester.pumpAndSettle();
      expect(requests, [('Who owns the review?', 'meeting:$id', id)]);
      expect(f.shell.meetingFeature.meetingPanel, 'Chat');
      expect(f.shell.chatFeature.questionFor(id).text, isEmpty);
      expect(f.shell.chatFeature.asking, false);
    },
  );

  testWidgets(
    'capture indicator reopens its meeting and shows only nonempty provisional segments',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final id = f.store.meeting('Live transcript fixture');
      f.connection.captureState = {
        'active': true,
        'meeting_id': id,
        'paused': true,
        'state': 'paused',
        'began': DateTime.now()
            .subtract(const Duration(seconds: 5))
            .millisecondsSinceEpoch,
        'provisional': {
          'microphone': 'Live microphone words',
          'playback': '',
          'imported': 'Live imported words',
        },
      };
      f.shell.update(() {
        f.shell.tab = 0;
        f.shell.meetingFeature.meetingPanel = 'Transcript';
        f.shell.meetingFeature.syncCapture();
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open transcription workspace'));
      // The capture pill's double-tap recognizer defers a single tap.
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(f.shell.tab, 3);
      expect(f.shell.meetingFeature.meetingId, id);
      expect(f.shell.meetingFeature.meetingSidecarVisible, true);
      expect(find.text('Live microphone words'), findsOneWidget);
      expect(find.text('Live imported words'), findsOneWidget);
      expect(find.textContaining('· Live'), findsNWidgets(2));
      f.connection.captureState = {};
      f.shell.update(() => f.shell.meetingFeature.syncCapture());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'desktop keyboard navigation, new note, cancelled import and help preserve workspace state',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      Future<void> shortcut(LogicalKeyboardKey key) async {
        final modifier = Platform.isMacOS
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
      }

      for (final (key, tab) in [
        (LogicalKeyboardKey.digit1, 3),
        (LogicalKeyboardKey.digit2, 1),
        (LogicalKeyboardKey.digit3, 0),
        (LogicalKeyboardKey.digit4, 5),
        (LogicalKeyboardKey.digit5, 6),
      ]) {
        await shortcut(key);
        expect(f.shell.tab, tab);
      }
      f.shell.meetingFeature.noteTitle.text = 'Old title';
      f.shell.meetingFeature.noteBody.text = 'Old draft';
      await shortcut(LogicalKeyboardKey.keyN);
      expect(f.shell.tab, 2);
      expect(f.shell.meetingFeature.noteId, isNull);
      expect(f.shell.meetingFeature.noteTitle.text, isEmpty);
      expect(f.shell.meetingFeature.noteBody.text, isEmpty);
      const picker = MethodChannel('plugins.flutter.io/file_selector');
      var openings = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, (
        _,
      ) async {
        openings++;
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          picker,
          null,
        ),
      );
      await shortcut(LogicalKeyboardKey.keyO);
      expect(openings, 1);
      expect(f.store.sources, isEmpty);
      await tester.tap(find.byTooltip('Help'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('ask a question with citations'),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'connected service settings refresh, change interval, disconnect and cancel sign-in without deleting imports',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final account = SettingsAccount(Directory('${f.root.path}/google'));
      addTearDown(account.close);
      final google = SettingsSources();
      f.connection.account = account;
      f.connection.connectedSources = google;
      final id = f.store.importText(
        'Retained Drive import',
        'Saved text',
        'text/plain',
        'fixture',
      );
      f.shell.update(() => f.shell.tab = 6);
      await tester.pumpAndSettle();
      final refresh = find.text('Refresh Google');
      await tester.ensureVisible(refresh);
      expect(find.text('Connected as fixture@example.test'), findsOneWidget);
      google.gate = Completer<void>();
      await tester.tap(refresh);
      await tester.pump();
      expect(google.refreshes, 1);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Refresh Google'),
            )
            .onPressed,
        isNull,
      );
      google.gate!.complete();
      await tester.pumpAndSettle();
      final interval = find.text('4 hours');
      await tester.ensureVisible(interval);
      await tester.tap(interval);
      await tester.pumpAndSettle();
      await tester.tap(find.text('8 hours').last);
      await tester.pumpAndSettle();
      expect(f.store.preference('googleRefreshHours'), '8');
      await tester.ensureVisible(find.text('Disconnect Google'));
      await tester.tap(find.text('Disconnect Google'));
      await tester.pumpAndSettle();
      expect(account.disconnects, 1);
      expect(f.store.sourceById(id).single['content'], 'Saved text');
      expect(
        find.text('Disconnected; imported documents remain on this device.'),
        findsOneWidget,
      );
      f.shell.update(() => account.pending = true);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Cancel sign-in'));
      await tester.tap(find.text('Cancel sign-in'));
      await tester.pumpAndSettle();
      expect(account.cancellations, 1);
      expect(account.signingIn, false);
    },
  );

  for (final partial in [false, true]) {
    testWidgets(
      'local discovery ${partial ? 'reports partial failure after attempting every selection' : 'imports every selected file'}',
      (tester) async {
        final f = await ControllerFixture.mount(tester);
        final folder = Directory('${f.root.path}/documents')..createSync();
        final paths = [
          for (final name in ['alpha.txt', 'beta.md', 'gamma.txt'])
            (File(
              '${folder.path}/$name',
            )..writeAsStringSync('Fixture $name')).resolveSymbolicLinksSync(),
        ];
        // Discovery canonicalizes selected folders (including macOS /tmp).
        // Exercise an alias on every host so path expectations stay portable.
        final selected = Link('${f.root.path}/selected-documents')
          ..createSync(folder.path);
        f.connection.replies[Operation.sourcesImportFile] = {};
        if (partial)
          f.connection.fileFailures[paths[1]] = StateError(
            'Parser rejected file',
          );
        final pending =
            f.shell.run(
                  () =>
                      f.shell.sourceFeature.findLocalFiles(
                            roots: <String>[selected.path],
                          )
                          as Future<void>,
                )
                as Future<void>;
        await tester.pump();
        await pumpUntil(
          tester,
          () => find.textContaining('3 files found').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Select all shown'));
        await tester.pump();
        await tester.tap(find.text('Import selected (3)'));
        await tester.pumpAndSettle();
        await pending;
        final imported = f.connection.calls
            .where((c) => c.$1 == Operation.sourcesImportFile)
            .map((c) => c.$2['path'])
            .toList();
        expect(imported, unorderedEquals(paths));
        if (partial) {
          expect(
            f.shell.error,
            contains(
              'Imported 2 files. beta.md: Bad state: Parser rejected file',
            ),
          );
        } else {
          expect(f.shell.error, isEmpty);
        }
      },
    );
  }

  for (final grid in [false, true]) {
    testWidgets(
      '${grid ? 'grid' : 'list'} source actions retry indexing and delete only the selected source',
      (tester) async {
        final f = await ControllerFixture.mount(tester);
        final id = f.store.importText(
          'Action target',
          'Text',
          'text/plain',
          'fixture',
        );
        final retained = f.store.importText(
          'Retained source',
          'Other text',
          'text/plain',
          'fixture',
        );
        f.store.state(id, 'failed', 'Index interrupted');
        f.shell.update(() {
          f.shell.tab = 0;
          f.shell.sourceFeature.gridView = grid;
        });
        await tester.pumpAndSettle();
        final target = grid
            ? find.ancestor(
                of: find.text('Action target'),
                matching: find.byType(ListTile),
              )
            : find
                  .ancestor(
                    of: find.text('Action target'),
                    matching: find.byType(Row),
                  )
                  .first;
        final retry = find.descendant(
          of: target,
          matching: find.byTooltip('Index / retry'),
        );
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(f.connection.indexed, [id]);
        await tester.tap(
          find.descendant(
            of: target,
            matching: find.byTooltip('Delete source'),
          ),
        );
        await tester.pumpAndSettle();
        expect(f.connection.deleted, [id]);
        expect(f.store.sourceById(id), isEmpty);
        expect(f.store.sourceById(retained), hasLength(1));
      },
    );
  }

  testWidgets(
    'summary history keeps earlier edits separate from the current version and permits regeneration',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final id = f.store.meeting('Versioned summary');
      f.store.artifact(id, 'summary', 'Earlier summary', 'fixture');
      final previous = f.store.db.lastInsertRowId;
      f.store.artifact(id, 'summary', 'Current summary', 'fixture');
      final latest = f.store.db.lastInsertRowId;
      f.shell.update(() {
        f.shell.meetingFeature.meetingId = id;
        f.shell.meetingFeature.meetingPanel = 'Summary';
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Previous versions'));
      await tester.pumpAndSettle();
      expect(find.text('Earlier summary', findRichText: true), findsOneWidget);
      await tester.tap(find.byTooltip('Edit previous version'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Corrected earlier summary',
      );
      await tester.tap(find.text('Save edit'));
      await tester.pumpAndSettle();
      expect(
        f.store.rows('SELECT edited FROM artifacts WHERE id=?', [
          previous,
        ]).single['edited'],
        'Corrected earlier summary',
      );
      expect(
        f.store.rows('SELECT generated,edited FROM artifacts WHERE id=?', [
          latest,
        ]).single,
        {'generated': 'Current summary', 'edited': null},
      );
      await tester.tap(find.byTooltip('Generate Summary'));
      await tester.pumpAndSettle();
      expect(f.connection.calls.last.$1, Operation.meetingsGenerate);
      expect(f.connection.calls.last.$2, {'id': id, 'kind': 'summary'});
    },
  );

  testWidgets(
    'meeting question detection errors have an explicit retry for the owning meeting',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final id = f.store.meeting('Detection retry');
      f.connection.captureState = {
        'proactive': {
          'errors': {'$id': 'Detector unavailable'},
        },
      };
      f.connection.replies[Operation.meetingsRetryDetection] = null;
      f.shell.update(() {
        f.shell.meetingFeature.meetingId = id;
        f.shell.meetingFeature.meetingPanel = 'Live Q&A';
      });
      await tester.pumpAndSettle();
      expect(find.text('Detector unavailable'), findsOneWidget);
      await tester.tap(find.text('Retry detection'));
      await tester.pumpAndSettle();
      expect(f.connection.calls.last.$1, Operation.meetingsRetryDetection);
      expect(f.connection.calls.last.$2, {'id': id});
    },
  );
}
