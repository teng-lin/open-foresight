import 'sql_support_test_bootstrap.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/google_calendar_event.dart';
import 'package:foresight_core/src/persistence/google_connection_queries.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Store store;
  late Domain domain;
  late Application app;
  setUp(() {
    final root = createTestTempDirectorySync('rename-');
    store = Store('${root.path}/app.db');
    domain = Domain(
      store,
      Helper('${root.path}/helper.sock', '${root.path}/helper'),
    );
    app = Application(domain);
    addTearDown(() async {
      await app.close();
      domain.close();
      await domain.helper.close();
      store.close();
    });
  });

  Future<void> rename(int id, String title, {String? epoch}) async {
    await app.call('meetings.rename', {
      'id': id,
      'title': title,
      if (epoch != null) 'workspace_epoch': epoch,
    });
  }

  Matcher error(RpcErrorCode code) =>
      throwsA(isA<RpcError>().having((e) => e.code, 'code', code));

  test(
    'rename persists, trims and preserves meeting content and identity',
    () async {
      final id = store.meeting('Original');
      store.saveMeetingNotes(id, 'My notes');
      store.transcript(id, 'My transcript', true, 0, 1000, 'microphone');
      store.artifact(id, 'summary', 'My summary', 'fixture');
      final before = store.rows('SELECT * FROM meetings').single;
      await rename(id, '  Planning 中文  ', epoch: store.workspaceEpoch);
      final detail = await app.call('meetings.get', {'id': id}) as Map;
      expect((detail['meeting'] as Map)['title'], 'Planning 中文');
      expect((detail['notes'] as List).single['body'], 'My notes');
      expect((detail['transcript'] as List).single['text'], 'My transcript');
      expect((detail['artifacts'] as List).single['generated'], 'My summary');
      expect(store.rows('SELECT id,state,revision FROM meetings').single, {
        'id': id,
        'state': before['state'],
        'revision': before['revision'],
      });
      expect(store.meetingQueries.collection().single.title, 'Planning 中文');
      expect(store.meetingQueries.exportNotes().single.title, 'Planning 中文');
      final reader = Store.readOnly(store.path);
      addTearDown(reader.close);
      expect(reader.meetingQueries.workspace(id)!.title, 'Planning 中文');
      final path = store.path;
      store.close();
      store = Store(path);
      expect(store.meetingQueries.workspace(id)!.title, 'Planning 中文');
      expect(
        store
            .rows('SELECT title_manually_edited FROM meetings')
            .single
            .values
            .single,
        1,
      );
    },
  );

  test('invalid names and missing meetings leave titles unchanged', () async {
    final id = store.meeting('Original');
    for (final title in ['', ' \n\t ', 'x' * 501]) {
      await expectLater(rename(id, title), error(RpcErrorCode.invalidArgument));
    }
    for (final args in [
      {'id': id, 'title': 42},
      {'id': id},
      {'id': '$id', 'title': 'New'},
    ]) {
      await expectLater(
        app.call('meetings.rename', args),
        error(RpcErrorCode.invalidArgument),
      );
    }
    await expectLater(rename(id + 1, 'Missing'), error(RpcErrorCode.notFound));
    expect(store.meetingQueries.workspace(id)!.title, 'Original');
    expect(
      store
          .rows('SELECT title_manually_edited FROM meetings')
          .single
          .values
          .single,
      0,
    );
    await rename(id, 'x' * 500);
    expect(store.meetingQueries.workspace(id)!.title, 'x' * 500);
  });

  test('a stale workspace cannot rename a meeting with a reused ID', () async {
    final id = store.meeting('Original');
    await expectLater(
      rename(id, 'Wrong', epoch: 'retired-workspace'),
      error(RpcErrorCode.notFound),
    );
    expect(store.meetingQueries.workspace(id)!.title, 'Original');
  });

  test(
    'calendar refresh respects explicit names and still refreshes event details',
    () async {
      GoogleCalendarUpdate event(String key, String title, int start) =>
          GoogleCalendarUpdate(
            key: key,
            account: 'account',
            calendar: 'primary',
            eventId: key,
            title: title,
            status: 'confirmed',
            metadata: '{"summary":"$title"}',
            starts: start,
            ends: start + 1000,
          );
      final calendar = GoogleConnectionQueries(store);
      calendar.storeCalendarEvent(event('event', 'Calendar title', 1000));
      final id = store.meetingQueries.collection().single.id;
      calendar.storeCalendarEvent(
        event('event', 'Updated calendar title', 2000),
      );
      expect(
        store.meetingQueries.workspace(id)!.title,
        'Updated calendar title',
      );
      // Saving even the current name expresses an explicit naming preference.
      await rename(id, 'Updated calendar title');
      calendar.storeCalendarEvent(event('event', 'Remote replacement', 3000));
      expect(
        store.meetingQueries.workspace(id)!.title,
        'Updated calendar title',
      );
      expect(store.meetingQueries.workspace(id)!.starts, 3000);
      expect(
        store.meetingQueries.calendarEventMetadata(id),
        contains('Remote replacement'),
      );
      calendar.storeCalendarEvent(event('other', 'Another event', 4000));
      calendar.storeCalendarEvent(event('other', 'Another update', 5000));
      expect(
        store.meetingQueries.collection().map((m) => m.title),
        contains('Another update'),
      );
    },
  );
}
