import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/remote.dart';
import 'controller_fixture.dart';

void main() {
  testWidgets('enhanced notes can be copied, hidden, restored and edited', (
    tester,
  ) async {
    final f = await ControllerFixture.mount(tester);
    final id = f.store.meeting('Enhanced notes fixture');
    f.store.saveMeetingNotes(id, 'Original notes');
    f.store.artifact(
      id,
      'enhanced_notes',
      'Enhanced fixture content',
      'fixture',
    );
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData')
          copied = (call.arguments as Map)['text'] as String;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    f.shell.update(() => f.shell.meetingFeature.meetingId = id);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy enhanced notes'));
    await tester.pump();
    expect(copied, 'Enhanced fixture content');
    await tester.tap(find.byTooltip('Hide enhanced notes'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Copy enhanced notes'), findsNothing);
    await tester.tap(find.byTooltip('Show enhanced notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit enhanced notes'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'User corrected enhancement',
    );
    await tester.tap(find.text('Save edit'));
    await tester.pumpAndSettle();
    expect(f.store.meetingEnhancedNotes(id), 'User corrected enhancement');
    expect(f.store.meetingNoteRows(id).single['last_manual_edit'], isNotNull);
  });
  for (final preview in [false, true]) {
    testWidgets(
      '${preview ? 'preview menu' : 'workspace toolbar'} applies all note formats and persists style',
      (tester) async {
        final f = await ControllerFixture.mount(tester);
        final id = f.store.meeting('Toolbar formatting');
        f.store.saveMeetingNotes(id, 'Selected words');
        final meeting = f.shell.meetingFeature;
        if (preview) {
          f.shell.update(() {
            meeting.meetingPreviewId = id;
            meeting.meetingPreviewTab = 'Notes';
          });
        } else {
          f.shell.update(() {
            meeting.meetingId = id;
          });
        }
        await tester.pumpAndSettle();
        final controller = meeting.meetingNotesController;
        for (final (label, expected) in [
          ('Bold', '**Selected words**'),
          ('Italic', '*Selected words*'),
          ('Bullet list', '\n- Selected words'),
          ('Numbered list', '\n1. Selected words'),
          ('Heading', '\n# Selected words'),
        ]) {
          f.store.saveMeetingNotes(id, 'Selected words');
          meeting.loadMeetingNotes(id, acceptedSave: true);
          controller.selection = const TextSelection(
            baseOffset: 0,
            extentOffset: 14,
          );
          if (preview) {
            await tester.tap(find.byTooltip('Format notes'));
            await tester.pumpAndSettle();
            await tester.tap(find.text(label));
          } else {
            await tester.tap(find.byTooltip(label));
          }
          await tester.pumpAndSettle();
          expect(controller.text, expected);
          await meeting.saveMeetingNotes();
        }
        await meeting.saveMeetingNotes();
        expect(
          f.store.meetingNoteRows(id).single['body'],
          '\n# Selected words',
        );
        await tester.tap(find.byType(DropdownButton<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Concise').last);
        await tester.pumpAndSettle();
        expect(f.store.preference('noteStyle'), 'Concise');
      },
    );
  }
  testWidgets(
    'meeting note formatting preserves selection and saves before enhancement with retry',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final id = f.store.meeting('Formatting fixture');
      f.store.saveMeetingNotes(id, 'Hello world');
      final meeting = f.shell.meetingFeature;
      f.shell.update(() {
        meeting.meetingId = id;
      });
      await tester.pumpAndSettle();
      final controller = meeting.meetingNotesController;
      controller.selection = const TextSelection(
        baseOffset: 6,
        extentOffset: 11,
      );
      meeting.formatMeetingNotes('**', '**');
      expect(controller.text, 'Hello **world**');
      expect(controller.selection.extentOffset, 13);
      await meeting.saveMeetingNotes();
      expect(f.store.meetingNoteRows(id).single['body'], 'Hello **world**');
      controller.selection = const TextSelection.collapsed(offset: -1);
      meeting.formatMeetingNotes('\n- ');
      expect(controller.text, 'Hello **world**\n- ');
      f.connection.failures[Operation.meetingsEnhance] = StateError(
        'generation unavailable',
      );
      await meeting.enhanceMeetingNotes(id);
      expect(meeting.meetingEnhanceStatus, contains('generation unavailable'));
      expect(meeting.meetingEnhancing, false);
      expect(f.store.meetingNoteRows(id).single['body'], controller.text);
      f.connection.failures.clear();
      await meeting.enhanceMeetingNotes(id);
      expect(meeting.meetingEnhanceStatus, isEmpty);
      await meeting.generateMeeting('summary', id: id);
      expect(f.connection.calls.last.$2, {'id': id, 'kind': 'summary'});
      await meeting.indexMeeting(id);
      expect(f.connection.calls.last.$1, Operation.meetingsIndex);
      final imported = await meeting.importText(
        'Meeting text',
        'Saved evidence',
        'text/plain',
        'fixture',
      );
      expect(f.store.sourceById(imported).single['content'], 'Saved evidence');
      expect(meeting.exportMeetingMarkdown(), contains('Hello **world**'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'echo cancellation status distinguishes pending, paused, fallback and active capture',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final meeting = f.shell.meetingFeature;
      final cases = [
        (<String, dynamic>{}, 'Reduce system playback'),
        ({'active': true, 'paused': true}, 'apply when recording resumes'),
        (
          {
            'active': true,
            'echo_cancellation': {'pending': true},
          },
          'Applying echo cancellation',
        ),
        (
          {
            'active': true,
            'echo_cancellation': {'fallback_status': 1},
          },
          'unavailable',
        ),
        (
          {
            'active': true,
            'echo_cancellation': {'restart_required': true},
          },
          'Restart recording',
        ),
        (
          {
            'active': true,
            'echo_cancellation': {'active': true},
          },
          'active for this microphone',
        ),
        ({'active': true}, 'off'),
      ];
      for (final (capture, text) in cases) {
        f.connection.captureState = capture;
        expect(meeting.echoCancellationDescription, contains(text));
      }
      f.connection.captureState = {};
    },
  );
  testWidgets(
    'transcript import cancellation and selected text use the owning meeting',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final id = f.store.meeting('Imported transcript');
      final meeting = f.shell.meetingFeature;
      final transcript = File('${f.root.path}/transcript.txt')
        ..writeAsStringSync('Speaker: What is the deadline?\nNext Friday.');
      f.connection.replies[Operation.meetingsTranscript] = null;
      String? selected;
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => selected == null ? null : [selected],
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await meeting.importMeetingTranscript(id);
      expect(f.store.meetingTranscript(id), isEmpty);
      selected = transcript.path;
      await tester.runAsync(() => meeting.importMeetingTranscript(id));
      expect(f.connection.calls.last.$1, Operation.meetingsTranscript);
      expect(f.connection.calls.last.$2, {
        'id': id,
        'text': transcript.readAsStringSync(),
        'source': 'imported transcript',
        // A retry after a lost reply reuses it, so the import appends once.
        'idempotency_key': isA<String>(),
        // The meeting ID belongs to the workspace the picker opened in.
        'workspace_epoch': f.store.workspaceEpoch,
      });
    },
  );
  testWidgets(
    'editing generated artifacts preserves user text and supports cancellation',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final id = f.store.meeting('Artifact fixture');
      f.store.artifact(id, 'summary', 'Generated summary', 'fixture');
      final artifact = f.store.rows(
        'SELECT * FROM artifacts WHERE meeting_id=?',
        [id],
      ).single;
      final meeting = f.shell.meetingFeature;
      var edit = meeting.editArtifact(artifact);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'User summary',
      );
      await tester.tap(find.text('Save edit'));
      await tester.pumpAndSettle();
      await edit;
      expect(
        f.store.rows('SELECT edited FROM artifacts WHERE id=?', [
          artifact['id'],
        ]).single['edited'],
        'User summary',
      );
      edit = meeting.editArtifact({...artifact, 'edited': 'User summary'});
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await edit;
      expect(
        f.store.rows('SELECT edited FROM artifacts WHERE id=?', [
          artifact['id'],
        ]).single['edited'],
        'User summary',
      );
    },
  );
}
