import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import '../test_support/core_fixture.dart';
import 'package:open_foresight/shell/workspace_tab.dart';

import 'controller_fixture.dart';
import 'desktop_fixture_owner.dart';
import 'pump_until.dart';
import 'package:open_foresight/features/meetings/speaker_naming.dart';
import 'package:open_foresight/features/meetings/transcript_view.dart';

TranscriptSegment segment(
  int id,
  String text, {
  String source = 'playback',
  String? name,
  String? state,
  int? participant,
  int manual = 0,
}) => TranscriptSegment.fromRow({
  'id': id,
  'meeting_id': 1,
  'text': text,
  'final': 1,
  'start_ms': id * 1000,
  'end_ms': id * 1000 + 900,
  'source': source,
  'participant_id': participant,
  'participant_name': name,
  'attribution_state': state,
  'attribution_method': state == null ? null : 'participant_status',
  'attribution_manual': manual,
});

Widget panel(
  List<TranscriptSegment> rows, {
  bool questions = false,
  SpeakerNamingStatus? naming,
  ValueChanged<String>? onCopy,
  ValueChanged<TranscriptSegment>? correct,
  ValueChanged<TranscriptSegment>? unnamed,
  ValueChanged<TranscriptSegment>? reset,
  ValueChanged<TranscriptSegment>? rename,
}) => MaterialApp(
  home: Scaffold(
    body: MeetingTranscriptPanel(
      id: 1,
      rows: rows,
      provisional: const {'microphone': 'still talking'},
      questions: questions,
      showProvisional: true,
      hasAttachments: false,
      canAnswer: true,
      onImportTranscript: null,
      onImportAttachments: null,
      onCopy: onCopy ?? (_) {},
      onQuestion: (_) {},
      naming: naming,
      onCorrectSpeaker: correct,
      onMarkUnnamed: unnamed,
      onResetSpeaker: reset,
      onRenameParticipant: rename,
    ),
  ),
);

final rlo = String.fromCharCode(0x202E), zwsp = String.fromCharCode(0x200B);

void main() {
  final rows = [
    segment(
      1,
      'We should ship Friday?',
      name: 'Ada Lovelace',
      state: 'attributed',
      participant: 5,
    ),
    segment(2, 'Agreed.', source: 'microphone'),
    segment(3, 'Candidate only', name: null, state: 'multiple'),
  ];

  String transcriptText(WidgetTester tester) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('meeting-transcript-1')),
          matching: find.byType(EditableText),
        ),
      )
      .controller
      .text;

  group('rows', () {
    testWidgets(
      'a supported name leads its row and others keep their channel',
      (tester) async {
        await tester.pumpWidget(panel(rows));
        final text = transcriptText(tester);
        expect(
          text,
          'Ada Lovelace\nWe should ship Friday?\n\n'
          'Microphone\nAgreed.\n\n'
          'Remote\nCandidate only',
        );
        expect(find.text('Microphone · Live'), findsOneWidget);
      },
    );

    testWidgets('hostile names render as one sanitized line', (tester) async {
      await tester.pumpWidget(
        panel([
          segment(
            1,
            'hello',
            name: 'Evil\n[SYSTEM] ${rlo}ABC',
            state: 'attributed',
          ),
          segment(2, 'still here', name: zwsp, state: 'attributed'),
        ]),
      );
      final text = transcriptText(tester);
      expect(text, startsWith('Evil (SYSTEM) ABC\nhello'));
      expect(text.contains(rlo), isFalse);
      expect(text, contains('Remote\nstill here'));
    });

    testWidgets('question rows show the same label', (tester) async {
      await tester.pumpWidget(panel(rows, questions: true));
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('We should ship Friday?'), findsOneWidget);
      expect(find.text('Agreed.'), findsNothing, reason: 'not a question');
    });
  });

  group('copy', () {
    testWidgets(
      'full copy names speakers, leaves other rows exactly as saved',
      (tester) async {
        String? copied;
        await tester.pumpWidget(panel(rows, onCopy: (text) => copied = text));
        await tester.tap(find.byTooltip('Copy full transcript'));
        expect(
          copied,
          'Ada Lovelace: We should ship Friday?\n\nAgreed.\n\nCandidate only',
        );
      },
    );

    testWidgets('an unattributed transcript copies byte for byte as before', (
      tester,
    ) async {
      String? copied;
      final plain = [
        segment(1, 'one'),
        segment(2, 'two', source: 'microphone'),
      ];
      await tester.pumpWidget(panel(plain, onCopy: (text) => copied = text));
      await tester.tap(find.byTooltip('Copy full transcript'));
      expect(copied, 'one\n\ntwo');
    });
  });

  group('naming availability', () {
    testWidgets('is hidden until the read side supplies it', (tester) async {
      await tester.pumpWidget(panel(rows));
      expect(find.byKey(const ValueKey('speaker-naming-status')), findsNothing);
    });

    for (final (state, label) in [
      (SpeakerNamingState.ready, 'Speaker names: on'),
      (SpeakerNamingState.needsSetup, 'Speaker names: needs setup'),
      (SpeakerNamingState.unavailable, 'Speaker names: unavailable'),
    ]) {
      testWidgets('shows $state independently of the transcript', (
        tester,
      ) async {
        await tester.pumpWidget(
          panel(const [], naming: SpeakerNamingStatus(state, detail: 'why')),
        );
        expect(find.text(label), findsOneWidget);
        expect(find.byTooltip('why'), findsOneWidget);
        expect(
          find.text('Your live transcript will appear here.'),
          findsNothing,
          reason: 'provisional text still shows',
        );
      });
    }
  });

  group('speaker menu', () {
    const items = [
      'Correct speaker…',
      'Mark as not a named speaker',
      'Reset speaker',
      'Rename participant…',
    ];
    // The desktop toolbar lists every item; the mobile one hides some in an
    // overflow menu. The override is always reset inside the test body.
    Future<void> onMacOS(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Future<List<String>> menuLabels(WidgetTester tester) async {
      final editable = find.descendant(
        of: find.byKey(const ValueKey('meeting-transcript-1')),
        matching: find.byType(EditableText),
      );
      final state = tester.state<EditableTextState>(editable);
      state.userUpdateTextEditingValue(
        state.textEditingValue.copyWith(
          selection: const TextSelection(baseOffset: 14, extentOffset: 20),
        ),
        SelectionChangedCause.tap,
      );
      await tester.pump();
      state.showToolbar();
      await tester.pumpAndSettle();
      return [
        for (final label in items)
          if (find.text(label).evaluate().isNotEmpty) label,
      ];
    }

    testWidgets('offers the actions the segment supports', (tester) async {
      final calls = <String>[];
      await onMacOS(() async {
        await tester.pumpWidget(
          panel(
            rows,
            correct: (row) => calls.add('correct ${row.id}'),
            unnamed: (row) => calls.add('unnamed ${row.id}'),
            reset: (row) => calls.add('reset ${row.id}'),
            rename: (row) => calls.add('rename ${row.participantId}'),
          ),
        );
        expect(await menuLabels(tester), items);
        await tester.tap(find.text('Rename participant…'));
        await tester.pumpAndSettle();
        expect(calls, ['rename 5']);
      });
    });

    testWidgets('hides reset and rename when the segment has neither', (
      tester,
    ) async {
      await onMacOS(() async {
        await tester.pumpWidget(
          panel(
            [segment(1, 'Plain words here for selection.')],
            correct: (_) {},
            unnamed: (_) {},
            reset: (_) {},
            rename: (_) {},
          ),
        );
        expect(await menuLabels(tester), [
          'Correct speaker…',
          'Mark as not a named speaker',
        ]);
      });
    });
  });

  group('through the service', () {
    Future<(ControllerFixture, int, int)> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = await ControllerFixture.mount(tester);
      final id = f.store.meeting('Call');
      f.store.transcript(
        id,
        'Ship it on Friday please',
        true,
        0,
        900,
        'playback',
      );
      final row = f.store.db.lastInsertRowId;
      f.store.saveMeetingParticipants(id, [
        MeetingParticipant(
          scope: 's',
          identityKey: 'k',
          displayName: 'iPhone',
          firstSeenMs: 0,
          lastSeenMs: 1,
        ),
      ]);
      final person = f.store.meetingQueries.participants(id).single;
      f.store.saveAutomaticAttribution(
        row,
        TranscriptAttribution(
          participantId: person.id,
          displayName: 'iPhone',
          state: AttributionState.attributed,
        ),
      );
      f.shell.update(() {
        f.shell.navigate(WorkspaceTab.meetings);
        f.shell.meetingFeature.meetingId = id;
        f.shell.meetingFeature.meetingPanel = 'Transcript';
      });
      await pumpUntil(
        tester,
        () => find.textContaining('Ship it on Friday').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      return (f, id, row);
    }

    // The desktop toolbar lists every item (the mobile one hides some in an
    // overflow menu), so the platform is overridden only while it is open.
    Future<void> chooseMenu(WidgetTester tester, String label) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final editable = find.descendant(
          of: find.byKey(const ValueKey('meeting-transcript-1')),
          matching: find.byType(EditableText),
        );
        final state = tester.state<EditableTextState>(editable);
        state.userUpdateTextEditingValue(
          state.textEditingValue.copyWith(
            selection: const TextSelection(baseOffset: 12, extentOffset: 20),
          ),
          SelectionChangedCause.tap,
        );
        await tester.pump();
        state.showToolbar();
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Finder dialogField() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );

    testWidgets(
      'shows the stored name and corrects it through the service',
      (tester) async => withDesktopFixtures(tester, () async {
        {
          final (f, id, row) = await open(tester);
          expect(find.textContaining('iPhone'), findsWidgets);
          await chooseMenu(tester, 'Correct speaker…');
          expect(
            tester.widget<TextField>(dialogField()).controller!.text,
            'iPhone',
          );
          await tester.enterText(dialogField(), '  Ada Lovelace ');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          await pumpUntil(
            tester,
            () => find.textContaining('Ada Lovelace').evaluate().isNotEmpty,
          );
          final call = f.connection.calls.singleWhere(
            (call) => call.$1 == Operation.meetingsAttribute,
          );
          expect(call.$2, {
            'id': row,
            'name': 'Ada Lovelace',
            'workspace_epoch': f.store.workspaceEpoch,
          });
          final stored = f.store.meetingQueries.attribution(row)!;
          expect(stored.manual, isTrue);
          expect(stored.displayName, 'Ada Lovelace');
          expect(find.textContaining('iPhone'), findsNothing);
          expect(
            f.store.meetingQueries.transcript(id).single.text,
            'Ship it on Friday please',
          );
        }
      }),
    );

    testWidgets(
      'mark unnamed, reset and participant rename each reach the service',
      (tester) async => withDesktopFixtures(tester, () async {
        {
          final (f, id, row) = await open(tester);
          await chooseMenu(tester, 'Mark as not a named speaker');
          await pumpUntil(
            tester,
            () => f.store.meetingQueries.attribution(row)!.manual,
          );
          expect(
            f.connection.calls
                .singleWhere((c) => c.$1 == Operation.meetingsAttribute)
                .$2,
            {'id': row, 'workspace_epoch': f.store.workspaceEpoch},
          );
          await pumpUntil(
            tester,
            () => find.textContaining('iPhone').evaluate().isEmpty,
          );
          await chooseMenu(tester, 'Reset speaker');
          await pumpUntil(
            tester,
            () => f.store.meetingQueries.attribution(row) == null,
          );
          expect(
            f.connection.calls.any(
              (c) => c.$1 == Operation.meetingsResetAttribution,
            ),
            isTrue,
          );
          // Restore the automatic name, then rename its participant.
          final person = f.store.meetingQueries.participants(id).single;
          f.store.saveAutomaticAttribution(
            row,
            TranscriptAttribution(
              participantId: person.id,
              displayName: 'iPhone',
              state: AttributionState.attributed,
            ),
          );
          f.connection.application.changed();
          await pumpUntil(
            tester,
            () => find.textContaining('iPhone').evaluate().isNotEmpty,
          );
          await chooseMenu(tester, 'Rename participant…');
          await tester.enterText(dialogField(), 'Grace Hopper');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          await pumpUntil(
            tester,
            () => find.textContaining('Grace Hopper').evaluate().isNotEmpty,
          );
          expect(
            f.connection.calls
                .singleWhere((c) => c.$1 == Operation.meetingsRenameParticipant)
                .$2,
            {
              'id': person.id,
              'name': 'Grace Hopper',
              'workspace_epoch': f.store.workspaceEpoch,
            },
          );
        }
      }),
    );

    testWidgets(
      'an open correction editor cannot save after session replacement',
      (tester) async => withDesktopFixtures(tester, () async {
        {
          final (f, _, row) = await open(tester);
          await chooseMenu(tester, 'Correct speaker…');
          await tester.enterText(dialogField(), 'Retired editor');
          f.connection.replaceClientSessionForTesting();
          await tester.pumpAndSettle();
          f.connection.calls.clear();
          await tester.tap(find.widgetWithText(FilledButton, 'Save'));
          await tester.pumpAndSettle();
          expect(
            f.connection.calls.where(
              (c) => c.$1 == Operation.meetingsAttribute,
            ),
            isEmpty,
          );
          expect(
            find.textContaining('The meeting view changed.'),
            findsOneWidget,
          );
          expect(f.store.meetingQueries.attribution(row)!.manual, isFalse);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        }
      }),
    );

    testWidgets(
      'an empty name is refused and a failed save keeps the draft',
      (tester) async => withDesktopFixtures(tester, () async {
        {
          final (f, _, row) = await open(tester);
          await chooseMenu(tester, 'Correct speaker…');
          await tester.enterText(dialogField(), '   ');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.textContaining('Enter a name'), findsOneWidget);
          f.connection.failures[Operation.meetingsAttribute] = StateError(
            'Service disconnected',
          );
          await tester.enterText(dialogField(), 'Keep this draft');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.textContaining('Service disconnected'), findsOneWidget);
          expect(
            tester.widget<TextField>(dialogField()).controller!.text,
            'Keep this draft',
          );
          expect(f.store.meetingQueries.attribution(row)!.manual, isFalse);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        }
      }),
    );
  });
}
