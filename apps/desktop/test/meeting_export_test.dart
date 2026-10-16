import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:open_foresight/meeting_export.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/domain.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  late Directory directory;
  late Store store;
  final today = DateTime(2026, 10, 16);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('meeting-export-');
    store = Store('${directory.path}/app.db');
    Domain(
      store,
      OfflineHelper('${directory.path}/socket', '${directory.path}/helper'),
    ).application.google;
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  int meeting(String title, DateTime date, {String notes = ''}) {
    final id = store.meeting(title);
    store.db.execute(
      'UPDATE meeting_details SET created=? WHERE meeting_id=?',
      [date.millisecondsSinceEpoch, id],
    );
    if (notes.isNotEmpty) store.saveMeetingNotes(id, notes);
    return id;
  }

  test('date presets subtract their day counts from local midnight', () {
    expect(meetingExportRange(MeetingExportPeriod.anytime, today), isNull);
    for (final entry in {
      MeetingExportPeriod.today: 1,
      MeetingExportPeriod.last7Days: 7,
      MeetingExportPeriod.last30Days: 30,
      MeetingExportPeriod.last90Days: 90,
    }.entries) {
      final range = meetingExportRange(
        entry.key,
        DateTime(2026, 10, 16, 23, 59),
      )!;
      expect(range.end, today);
      expect(range.start, DateTime(2026, 10, 17 - entry.value));
    }
  });

  test(
    'export matches reference notes format and inclusive date boundaries',
    () {
      meeting(
        'Before',
        DateTime(2026, 10, 9, 23, 59),
        notes: 'excluded before',
      );
      final id = meeting(
        'Review',
        DateTime(2026, 10, 10),
        notes: '**中文 notes**',
      );
      store.artifact(id, 'summary', 'old generated summary', 'fixture');
      store.db.execute('UPDATE artifacts SET edited=? WHERE meeting_id=?', [
        'Edited summary',
        id,
      ]);
      store.transcript(id, 'Final segment one', true, 0, 1000, 'microphone');
      store.transcript(
        id,
        'Provisional excluded',
        false,
        1000,
        2000,
        'microphone',
      );
      store.transcript(id, '最终 segment two', true, 2000, 3000, 'playback');
      meeting(
        'End day',
        DateTime(2026, 10, 16, 23, 59, 59, 999),
        notes: 'Included end',
      );
      meeting('Tomorrow', DateTime(2026, 10, 17), notes: 'excluded after');
      meeting('Empty calendar placeholder', today);
      final result = composeMeetingExport(
        store,
        range: meetingExportRange(MeetingExportPeriod.last7Days, today),
      );
      expect(result.count, 2);
      expect(result.markdown, contains('**中文 notes**'));
      expect(result.markdown, isNot(contains('Edited summary')));
      expect(
        result.markdown,
        contains('## Review\nOct 10, 2026 12:00am\n\n**中文 notes**\n'),
      );
      expect(result.markdown, contains('Included end'));
      for (final excluded in [
        'excluded before',
        'excluded after',
        'Provisional excluded',
        'Final segment one',
        '最终 segment two',
        'old generated summary',
        'Empty calendar placeholder',
      ]) {
        expect(result.markdown, isNot(contains(excluded)));
      }
      expect(
        store
            .rows('SELECT generated,edited FROM artifacts')
            .single['generated'],
        'old generated summary',
      );
      expect(
        store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
          id,
        ]).single['body'],
        '**中文 notes**',
      );
    },
  );

  test(
    'calendar start takes precedence and linked events do not duplicate a note',
    () {
      final id = meeting(
        'Calendar meeting',
        DateTime(2026, 10, 1),
        notes: 'Scheduled today',
      );
      store.db.execute(
        'INSERT INTO calendar_events VALUES(?,?,?,?,?,?,?,?,?,?,?)',
        [
          'event',
          'account',
          'primary',
          'google-id',
          id,
          '',
          today.millisecondsSinceEpoch,
          today.add(const Duration(hours: 1)).millisecondsSinceEpoch,
          'confirmed',
          '{"htmlLink":"https://calendar.example.test/event?id=123&view=full"}',
          today.millisecondsSinceEpoch,
        ],
      );
      store.db.execute(
        'INSERT INTO calendar_events SELECT ?,account,?,google_id,meeting_id,'
        'source_id,starts,ends,status,metadata,synced FROM calendar_events WHERE event_key=?',
        ['duplicate-event', 'second-calendar', 'event'],
      );
      expect(
        composeMeetingExport(
          store,
          range: DateTimeRange(start: today, end: today),
        ).count,
        1,
      );
      expect(
        composeMeetingExport(store).markdown,
        contains(
          '[Oct 16, 2026 12:00am - 1:00am](https://calendar.example.test/event?id=123&view=full)',
        ),
      );
    },
  );

  test('export sorts newest first, trims edges and separates records', () {
    meeting('First', DateTime(2026, 10, 12, 9), notes: '\n  First note\n\n');
    meeting('Second', DateTime(2026, 10, 12, 10), notes: '  中文 note  \n');
    expect(
      composeMeetingExport(store).markdown,
      '## Second\nOct 12, 2026 10:00am\n\n中文 note\n\n\n\n'
      '## First\nOct 12, 2026 9:00am\n\nFirst note\n',
    );
    expect(
      store
          .rows('SELECT body FROM meeting_notes ORDER BY meeting_id')
          .map((row) => row['body']),
      ['\n  First note\n\n', '  中文 note  \n'],
    );
  });

  test(
    'export uses the original date patterns in the active Intl locale',
    () async {
      await initializeDateFormatting('fr_FR');
      meeting('Réunion', DateTime(2026, 10, 12, 15, 19), notes: 'Compte rendu');
      final result = Intl.withLocale(
        'fr_FR',
        () => composeMeetingExport(store),
      );
      expect(
        result.markdown,
        '## Réunion\noct. 12, 2026 3:19pm\n\nCompte rendu\n',
      );
    },
  );

  test(
    'single-note export matches the captured original file byte for byte',
    () {
      final id = meeting(
        '[New Meeting]',
        DateTime(2026, 10, 12, 15, 19),
        notes: 'Parity export fixture',
      );
      // The captured original item has an explicit 15:19–15:49 event range.
      store.db.execute(
        'INSERT INTO calendar_events VALUES(?,?,?,?,?,?,?,?,?,?,?)',
        [
          'captured-event',
          'account',
          'primary',
          'google-id',
          id,
          '',
          DateTime(2026, 10, 12, 15, 19).millisecondsSinceEpoch,
          DateTime(2026, 10, 12, 15, 49).millisecondsSinceEpoch,
          'confirmed',
          '{}',
          today.millisecondsSinceEpoch,
        ],
      );
      final transcriptOnly = meeting('Transcript only', today);
      store.transcript(
        transcriptOnly,
        'Saved speech is not a note',
        true,
        0,
        1000,
        'microphone',
      );
      final result = composeMeetingExport(store);
      expect(result.count, 1);
      expect(
        result.markdown,
        File('test/fixtures/reference_meeting_export.md').readAsStringSync(),
      );
    },
  );

  test(
    'inclusive custom range keeps the entire daylight-saving transition day',
    () {
      final day = DateTime(2026, 11, 1);
      meeting('Early', DateTime(2026, 11, 1, 0, 1), notes: 'early note');
      meeting('Late', DateTime(2026, 11, 1, 23, 59), notes: 'late note');
      meeting('Next day', DateTime(2026, 11, 2), notes: 'excluded next day');
      final result = composeMeetingExport(
        store,
        range: DateTimeRange(start: day, end: day),
      );
      expect(result.count, 2);
      expect(result.markdown, contains('late note'));
      expect(result.markdown, isNot(contains('excluded next day')));
    },
  );

  test('preset boundaries retain the original elapsed-day DST behavior', () {
    final midnight = DateTime(2026, 11, 5);
    final range = meetingExportRange(MeetingExportPeriod.last7Days, midnight)!;
    final first = midnight.subtract(const Duration(days: 6));
    expect(range.start, first);
    meeting(
      'Before elapsed boundary',
      first.subtract(const Duration(milliseconds: 1)),
      notes: 'excluded',
    );
    meeting('At elapsed boundary', first, notes: 'included first');
    meeting(
      'At end',
      DateTime(2026, 11, 5, 23, 59, 59, 999),
      notes: 'included last',
    );
    meeting('After end', DateTime(2026, 11, 6), notes: 'excluded after');
    final result = composeMeetingExport(store, range: range);
    expect(result.count, 2);
    expect(result.markdown, contains('included first'));
    expect(result.markdown, contains('included last'));
    expect(result.markdown, isNot(contains('excluded')));
    final custom = meetingExportRange(
      MeetingExportPeriod.custom,
      midnight,
      custom: DateTimeRange(
        start: DateTime(2026, 10, 30, 12),
        end: DateTime(2026, 11, 5, 12),
      ),
    )!;
    expect(custom.start, DateTime(2026, 10, 30));
    expect(custom.end, midnight);
  });

  testWidgets(
    'preview, copy, save cancellation and errors use the selected content',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      meeting('Today review', today, notes: 'Visible today');
      meeting('Old review', DateTime(2026, 1, 1), notes: 'Old notes');
      var saves = 0;
      String saved = '';
      String copied = '';
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MeetingExportDialog(
              store: store,
              now: today,
              save: (text) async {
                saved = text;
                saves++;
                if (saves == 1) return false;
                if (saves == 2)
                  throw const FileSystemException('fixture failure');
                return true;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Date range: Last 7 days'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byType(DropdownButtonFormField<MeetingExportPeriod>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Today').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('meeting-export-preview')),
            )
            .data,
        isNot(contains('Old notes')),
      );
      await tester.tap(find.text('Copy markdown'));
      await tester.pumpAndSettle();
      expect(copied, contains('Visible today'));
      expect(copied, isNot(contains('Old notes')));
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Download markdown'));
        await tester.pumpAndSettle();
        expect(saved, copied);
        if (i == 0)
          expect(find.text('Meeting notes saved successfully'), findsNothing);
        if (i == 1)
          expect(find.textContaining('fixture failure'), findsOneWidget);
      }
      expect(find.text('Meeting notes saved successfully'), findsOneWidget);
      await tester.tap(find.text('Date range: Today'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byType(DropdownButtonFormField<MeetingExportPeriod>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anytime').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Date range: Today'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('meeting-export-preview')),
            )
            .data,
        isNot(contains('Old notes')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'empty export disables actions and custom filter fits small windows',
    (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MeetingExportDialog(
              store: store,
              now: today,
              save: (_) async => true,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Date range: Last 7 days'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byType(DropdownButtonFormField<MeetingExportPeriod>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Start date:'), findsOneWidget);
      expect(find.textContaining('End date:'), findsOneWidget);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(
        find.text('No meeting notes found for the selected date range.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Download markdown'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Copy markdown'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Date range: Custom'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
