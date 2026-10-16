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

  void savedAt(int id, DateTime date) => store.db.execute(
    'UPDATE meeting_notes SET timestamp=? WHERE meeting_id=?',
    [date.millisecondsSinceEpoch, id],
  );

  int meeting(String title, DateTime date, {String notes = ''}) {
    final id = store.meeting(title);
    store.db.execute(
      'UPDATE meeting_details SET created=? WHERE meeting_id=?',
      [date.millisecondsSinceEpoch, id],
    );
    if (notes.isNotEmpty) {
      store.saveMeetingNotes(id, notes);
      savedAt(id, date);
    }
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

  test('export retains association title before current calendar title', () {
    final id = meeting('  ', today);
    store.db
        .execute('INSERT INTO calendar_events VALUES(?,?,?,?,?,?,?,?,?,?,?)', [
          'linked-event',
          'account',
          'primary',
          'google-id',
          id,
          '',
          today.millisecondsSinceEpoch,
          today.add(const Duration(hours: 1)).millisecondsSinceEpoch,
          'confirmed',
          '{"summary":"Captured title"}',
          today.millisecondsSinceEpoch,
        ]);
    store.saveMeetingNotes(id, 'Note body');
    store.db.execute('UPDATE calendar_events SET metadata=?', [
      '{"summary":"Current title"}',
    ]);
    expect(
      composeMeetingExport(store).markdown,
      startsWith('## Captured title\n'),
    );
    // Later nonempty names replace a duplicate ID's name without moving that
    // ID behind another association. Empty names never erase the known name.
    for (final link in [
      ('another-event', 'Another title'),
      ('linked-event', 'Updated association'),
      ('linked-event', ''),
    ]) {
      store.db.execute(
        'INSERT INTO meeting_note_events(meeting_id,event_key,title) VALUES(?,?,?)',
        [id, link.$1, link.$2],
      );
    }
    expect(
      composeMeetingExport(store).markdown,
      startsWith('## Updated association\n'),
    );
    store.db.execute('UPDATE meetings SET title=? WHERE id=?', [
      ' User title ',
      id,
    ]);
    expect(composeMeetingExport(store).markdown, startsWith('## User title\n'));
    store.db.execute('UPDATE meetings SET title=? WHERE id=?', ['', id]);
    store.db.execute('DELETE FROM calendar_events');
    expect(
      composeMeetingExport(store).markdown,
      startsWith('## Updated association\n'),
    );
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

  test(
    'standalone notes use saved dates and share formatting and filtering',
    () {
      store.saveNote(null, '  Standalone title  ', '  **Standalone body**\n');
      final standalone = store.db.lastInsertRowId;
      store.db.execute('UPDATE notes SET timestamp=? WHERE id=?', [
        DateTime(2026, 10, 16, 14, 5).millisecondsSinceEpoch,
        standalone,
      ]);
      meeting('Meeting', today, notes: 'Meeting body');
      store.saveNote(null, ' \t ', 'Fallback title body');
      store.db.execute('UPDATE notes SET timestamp=? WHERE id=?', [
        DateTime(2026, 10, 15, 12).millisecondsSinceEpoch,
        store.db.lastInsertRowId,
      ]);
      final before = store.rows('SELECT * FROM notes ORDER BY id');
      final all = composeMeetingExport(store);
      expect(all.count, 3);
      expect(
        all.markdown,
        startsWith(
          '## Standalone title\nOct 16, 2026 2:05pm\n\n**Standalone body**\n',
        ),
      );
      expect(
        all.markdown,
        contains(
          '## Untitled meeting\nOct 15, 2026 12:00pm\n\nFallback title body\n',
        ),
      );
      final filtered = composeMeetingExport(
        store,
        range: DateTimeRange(start: today, end: today),
      );
      expect(filtered.count, 2);
      expect(filtered.markdown, isNot(contains('Fallback title body')));
      expect(store.rows('SELECT * FROM notes ORDER BY id'), before);
    },
  );

  test(
    'global latest 1000 cap precedes body and date filtering across note types',
    () {
      final current = today.millisecondsSinceEpoch;
      store.db.execute('BEGIN');
      try {
        // Exactly 1,000 newer candidates: two visible today, 499 empty, and
        // 499 outside today's range. Both note types consume the same limit.
        for (var index = 0; index < 998; index++) {
          final timestamp = current - 100000000 - index;
          if (index.isEven) {
            final id = store.meeting('Empty meeting $index');
            store.saveMeetingNotes(id, ' \n ');
            store.db.execute(
              'UPDATE meeting_notes SET timestamp=? WHERE meeting_id=?',
              [timestamp, id],
            );
          } else {
            store.db.execute(
              'INSERT INTO notes(title,body,timestamp) VALUES(?,?,?)',
              ['Outside standalone $index', 'Outside body $index', timestamp],
            );
          }
        }
        final included = meeting(
          'Included meeting',
          today,
          notes: 'Included meeting body',
        );
        savedAt(included, today);
        store.db.execute(
          'INSERT INTO notes(title,body,timestamp) VALUES(?,?,?)',
          ['Included standalone', 'Included standalone body', current + 1],
        );
        final excluded = meeting(
          'Older saved meeting',
          today,
          notes: 'Excluded meeting body',
        );
        savedAt(excluded, DateTime(2000));
        // Its recent calendar date must not promote its old saved timestamp
        // into the acquired candidates.
        store.db.execute(
          'INSERT INTO calendar_events VALUES(?,?,?,?,?,?,?,?,?,?,?)',
          [
            'capped-event',
            'account',
            'primary',
            'capped-google',
            excluded,
            '',
            current,
            current + 3600000,
            'confirmed',
            '{}',
            current,
          ],
        );
        store.db
            .execute('INSERT INTO notes(title,body,timestamp) VALUES(?,?,?)', [
              'Older standalone',
              'Excluded standalone body',
              DateTime(1999).millisecondsSinceEpoch,
            ]);
        store.db.execute(
          "INSERT INTO notes(title,body,timestamp) VALUES('Unknown legacy','Excluded unknown body',NULL)",
        );
        store.db.execute('COMMIT');
      } catch (_) {
        store.db.execute('ROLLBACK');
        rethrow;
      }
      final all = composeMeetingExport(store);
      expect(all.count, 501);
      expect(all.markdown, isNot(contains('Excluded')));
      final filtered = composeMeetingExport(
        store,
        range: DateTimeRange(start: today, end: today),
      );
      expect(filtered.count, 2);
      expect(filtered.markdown, startsWith('## Included standalone\n'));
      expect(filtered.markdown, contains('Included meeting body'));
      expect(filtered.markdown, isNot(contains('Outside body')));
      expect(
        store.rows('SELECT timestamp FROM notes WHERE title=?', [
          'Unknown legacy',
        ]).single['timestamp'],
        isNull,
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

  test('export prefers the current enhanced notes and preserves raw notes', () {
    final id = meeting('Enhanced', today, notes: 'Raw shorthand');
    store.artifact(id, 'enhanced_notes', 'Old enhancement', 'fixture');
    store.artifact(
      id,
      'enhanced_notes',
      '  **Current enhancement**  \n',
      'fixture',
    );
    final current =
        store
                .rows(
                  "SELECT id FROM artifacts WHERE kind='enhanced_notes' ORDER BY id DESC",
                )
                .first['id']
            as int;
    store.artifact(id, 'summary', 'Unrelated summary', 'fixture');
    savedAt(id, today);
    expect(
      composeMeetingExport(store).markdown,
      '## Enhanced\nOct 16, 2026 12:00am\n\n**Current enhancement**\n',
    );

    store.editArtifact(current, '  User-edited enhancement  \n');
    savedAt(id, today);
    final before = store.rows('SELECT * FROM artifacts ORDER BY id');
    expect(
      composeMeetingExport(store).markdown,
      '## Enhanced\nOct 16, 2026 12:00am\n\nUser-edited enhancement\n',
    );
    expect(store.rows('SELECT * FROM artifacts ORDER BY id'), before);
    expect(
      store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
        id,
      ]).single['body'],
      'Raw shorthand',
    );

    // A cleared current enhancement falls back to the raw content. It does not
    // resurrect an older enhancement or the pre-edit generated text.
    store.editArtifact(current, ' \n\t');
    savedAt(id, today);
    expect(
      composeMeetingExport(store).markdown,
      '## Enhanced\nOct 16, 2026 12:00am\n\nRaw shorthand\n',
    );
  });

  test('enhanced-only notes export when the raw content is empty', () {
    final id = meeting('Enhanced only', today);
    store.saveMeetingNotes(id, ' \n');
    store.artifact(id, 'enhanced_notes', '\n  Enhanced content  \n', 'fixture');
    savedAt(id, today);
    final result = composeMeetingExport(store);
    expect(result.count, 1);
    expect(
      result.markdown,
      '## Enhanced only\nOct 16, 2026 12:00am\n\nEnhanced content\n',
    );
    store.editArtifact(
      store.rows('SELECT id FROM artifacts').single['id'] as int,
      '',
    );
    expect(composeMeetingExport(store).count, 0);
  });

  test(
    'unscheduled export uses saved note time and preserves unknown legacy time',
    () {
      final id = meeting(
        'Unscheduled',
        DateTime(2020, 1, 1),
        notes: 'Saved recently',
      );
      savedAt(id, DateTime(2026, 10, 16, 14, 5));
      final range = DateTimeRange(start: today, end: today);
      expect(
        composeMeetingExport(store, range: range).markdown,
        '## Unscheduled\nOct 16, 2026 2:05pm\n\nSaved recently\n',
      );
      store.db.execute(
        'UPDATE meeting_notes SET timestamp=NULL WHERE meeting_id=?',
        [id],
      );
      expect(composeMeetingExport(store, range: range).count, 0);
      expect(
        composeMeetingExport(store).markdown,
        contains('Jan 1, 2020 12:00am'),
      );
      expect(
        store.rows('SELECT timestamp FROM meeting_notes WHERE meeting_id=?', [
          id,
        ]).single['timestamp'],
        isNull,
      );
    },
  );

  test(
    'export trims note titles and falls back to event then default titles',
    () {
      final id = meeting('  Manual title \n', today, notes: 'Raw notes');
      store.db.execute(
        'INSERT INTO calendar_events VALUES(?,?,?,?,?,?,?,?,?,?,?)',
        [
          'title-event',
          'account',
          'primary',
          'google-id',
          id,
          '',
          today.millisecondsSinceEpoch,
          today.add(const Duration(hours: 1)).millisecondsSinceEpoch,
          'confirmed',
          '{"summary":"Calendar fallback"}',
          today.millisecondsSinceEpoch,
        ],
      );
      expect(
        composeMeetingExport(store).markdown,
        startsWith('## Manual title\n'),
      );
      store.db.execute('UPDATE meetings SET title=? WHERE id=?', [' \n ', id]);
      expect(
        composeMeetingExport(store).markdown,
        startsWith('## Calendar fallback\n'),
      );
      store.db.execute(
        "UPDATE calendar_events SET metadata='{}' WHERE meeting_id=?",
        [id],
      );
      expect(
        composeMeetingExport(store).markdown,
        startsWith('## Untitled meeting\n'),
      );
      store.db.execute('DELETE FROM calendar_events WHERE meeting_id=?', [id]);
      expect(
        composeMeetingExport(store).markdown,
        '## Untitled meeting\nOct 16, 2026 12:00am\n\nRaw notes\n',
      );
      expect(
        store.rows('SELECT title FROM meetings WHERE id=?', [
          id,
        ]).single['title'],
        ' \n ',
      );
    },
  );

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
