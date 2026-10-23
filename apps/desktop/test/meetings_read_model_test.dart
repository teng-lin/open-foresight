import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/features/meetings/read_model.dart';

class _Reader implements StoreReader {
  final queries = <ReadQuery<Object?>>[];
  final replies = <StreamController<ReadResult<Object?>>>[];
  int active = 0;
  @override
  String workspaceEpoch = 'epoch';
  @override
  String dataRevision = '1';
  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    queries.add(query);
    final reply = StreamController<ReadResult<Object?>>.broadcast(
      sync: true,
      onListen: () => active++,
      onCancel: () => active--,
    );
    replies.add(reply);
    return reply.stream.map((result) => result.asType<T>());
  }

  int index(String projection, [int? id]) => queries.lastIndexWhere(
    (q) =>
        q.projection == projection && (id == null || q.arguments['id'] == id),
  );
  void reply(
    int index,
    Object? value, {
    ReadFreshness freshness = ReadFreshness.current,
    RpcError? error,
  }) => replies[index].add(
    ReadResult(
      freshness: freshness,
      value: value,
      error: error,
      requestTag: 'test',
      sequence: index,
    ),
  );
  Future<void> close() async {
    for (final reply in replies) {
      await reply.close();
    }
  }

  ReadFreshness readFreshness = ReadFreshness.current;
  RpcError? readError;
  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) async => ReadResult(
    freshness: readFreshness,
    value: 'fixture' as T,
    error: readError,
    requestTag: 'action',
    sequence: 0,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected synchronous read ${invocation.memberName}');
}

class _Connection implements DesktopConnection {
  _Connection(this.store);
  @override
  final _Reader store;
  @override
  String? workspaceEpoch = 'epoch';
  @override
  Object clientSessionGeneration = Object();
  // Closed by each owning fixture.
  // ignore: close_sinks
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<void> _turn() => Future<void>(() {});
MeetingCollectionEntry _meeting(int id) => MeetingCollectionEntry.fromRow({
  'id': id,
  'title': 'Meeting $id',
  'state': 'saved',
  'revision': 1,
});

void main() {
  test(
    'current startup preferences initialize without notifying equal defaults',
    () async {
      final reader = _Reader();
      final connection = _Connection(reader);
      final current = <String, String>{};
      var publications = 0;
      final model = MeetingReadModel(
        connection: () => connection,
        changed: () => publications++,
        currentPreference: (key, value) => current[key] = value,
      );
      model.start();
      await _turn();
      final before = publications;
      for (final entry in MeetingReadModel.defaults.entries) {
        final index = reader.queries.indexWhere(
          (q) =>
              q.projection == 'preference' && q.arguments['key'] == entry.key,
        );
        reader.reply(index, entry.value);
      }
      await _turn();
      expect(current, MeetingReadModel.defaults);
      expect(publications, before);
      await model.dispose();
      await reader.close();
      await connection.events.close();
    },
  );

  test(
    'global and selected watches remain stable across status/data events and retire selection work',
    () async {
      final reader = _Reader();
      final connection = _Connection(reader);
      var changed = 0;
      final model = MeetingReadModel(
        connection: () => connection,
        changed: () => changed++,
      );
      model.start();
      expect(reader.queries, hasLength(2 + MeetingReadModel.defaults.length));
      reader.reply(reader.index('meetings'), [_meeting(1), _meeting(2)]);
      await _turn();
      expect(
        reader.queries.where((q) => q.projection == 'attachments'),
        hasLength(2),
      );
      final before = reader.queries.length;
      model.select(1, null);
      await _turn();
      expect(reader.queries.length, greaterThan(before));
      final selectedCount = reader.queries.length;
      expect(
        reader.queries.where((q) => q.projection == 'attachments'),
        hasLength(2),
      );
      final oldDetails = reader.index('meeting', 1),
          oldNote = reader.index('meeting_note', 1);
      reader.reply(
        oldDetails,
        MeetingDetails.fromRow({'id': 1, 'title': 'First owner'}),
      );
      reader.reply(
        oldNote,
        MeetingNoteData.fromRow({'meeting_id': 1, 'body': 'first draft'}),
      );
      await _turn();
      expect(model.meetingLoaded(1), true);
      expect(model.noteLoaded(1), true);
      expect(model.note(1)!.body, 'first draft');
      reader.dataRevision = '2';
      for (var i = 0; i < 20; i++) connection.events.add(null);
      await _turn();
      expect(reader.queries, hasLength(selectedCount));
      final snapshot = model.meetings, publications = changed;
      reader.reply(reader.index('meetings'), [_meeting(1), _meeting(2)]);
      await _turn();
      expect(model.meetings, same(snapshot));
      expect(changed, publications);
      model.select(2, null);
      await _turn();
      expect(reader.active, selectedCount);
      expect(model.meeting(1), isNull);
      reader.reply(
        oldDetails,
        MeetingDetails.fromRow({'id': 1, 'title': 'Retired reply'}),
      );
      reader.reply(
        oldNote,
        MeetingNoteData.fromRow({'meeting_id': 1, 'body': 'retired draft'}),
      );
      await _turn();
      expect(model.meeting(1), isNull);
      expect(model.note(1), isNull);
      reader.reply(
        reader.index('meeting', 2),
        MeetingDetails.fromRow({'id': 2, 'title': 'New owner'}),
      );
      await _turn();
      expect(model.meeting(2)!.title, 'New owner');
      await model.dispose();
      expect(reader.active, 0);
      final published = changed;
      reader.reply(
        reader.index('meeting', 2),
        MeetingDetails.fromRow({'id': 2, 'title': 'After dispose'}),
      );
      await _turn();
      expect(changed, published);
      await reader.close();
      await connection.events.close();
    },
  );

  test(
    'same-owner preview cannot certify note or model readiness and owner replacement clears retained values',
    () async {
      final reader = _Reader();
      final connection = _Connection(reader);
      final model = MeetingReadModel(
        connection: () => connection,
        changed: () {},
      );
      model.start(selected: 1);
      final note = reader.index('meeting_note', 1),
          speech = reader.index('model');
      final registration = ModelRegistration.fromRow({
        'kind': 'speech',
        'path': '/fixture/speech',
      });
      final data = MeetingNoteData.fromRow({
        'meeting_id': 1,
        'body': 'accepted',
      });
      reader.reply(note, data);
      reader.reply(speech, registration);
      await _turn();
      expect(model.noteLoaded(1), true);
      expect(model.speech, same(registration));
      reader.reply(note, data, freshness: ReadFreshness.preview);
      reader.reply(speech, registration, freshness: ReadFreshness.preview);
      await _turn();
      expect(model.note(1), same(data));
      expect(model.noteLoaded(1), false);
      expect(model.speech, isNull);
      reader.reply(
        note,
        null,
        freshness: ReadFreshness.failed,
        error: RpcError(RpcErrorCode.unavailable, 'read failed'),
      );
      await _turn();
      expect(model.note(1), same(data));
      expect(model.problem, contains('read failed'));
      connection.clientSessionGeneration = Object();
      connection.events.add(null);
      await _turn();
      expect(model.note(1), isNull);
      expect(model.speech, isNull);
      reader.reply(note, data);
      await _turn();
      expect(model.note(1), isNull);
      final current = reader.index('meeting_note', 1);
      reader.reply(
        current,
        MeetingNoteData.fromRow({'meeting_id': 1, 'body': 'replacement'}),
      );
      await _turn();
      expect(model.note(1)!.body, 'replacement');
      await model.dispose();
      await reader.close();
      await connection.events.close();
    },
  );
  test(
    'workspace adoption reconciles after a clear without accepting replies for the old client epoch',
    () async {
      final reader = _Reader();
      final connection = _Connection(reader);
      final model = MeetingReadModel(
        connection: () => connection,
        changed: () {},
      );
      model.start(selected: 1);
      final old = reader.index('meeting', 1);
      reader.reply(
        old,
        MeetingDetails.fromRow({'id': 1, 'title': 'Original workspace'}),
      );
      await _turn();
      reader.workspaceEpoch = 'replacement';
      connection.events.add(null);
      await _turn();
      final beforeAdopt = reader.index('meeting', 1);
      reader.reply(
        beforeAdopt,
        MeetingDetails.fromRow({'id': 1, 'title': 'Not adopted'}),
      );
      await _turn();
      expect(model.meeting(1), isNull);
      connection.workspaceEpoch = 'replacement';
      model.reconcile();
      reader.reply(
        reader.index('meeting', 1),
        MeetingDetails.fromRow({'id': 1, 'title': 'Adopted workspace'}),
      );
      await _turn();
      expect(model.meeting(1)!.title, 'Adopted workspace');
      reader.reply(
        old,
        MeetingDetails.fromRow({'id': 1, 'title': 'Late original'}),
      );
      await _turn();
      expect(model.meeting(1)!.title, 'Adopted workspace');
      await model.dispose();
      await reader.close();
      await connection.events.close();
    },
  );
  test(
    'action reads require current projections and retain concrete read failures',
    () async {
      final reader = _Reader();
      expect(
        await readCurrentMeeting(
          reader,
          StoreReadQueries.preference('fixture'),
        ),
        'fixture',
      );
      reader.readFreshness = ReadFreshness.preview;
      await expectLater(
        readCurrentMeeting(reader, StoreReadQueries.preference('fixture')),
        throwsA(isA<RpcError>()),
      );
      reader.readError = RpcError(
        RpcErrorCode.unavailable,
        'fixture unavailable',
      );
      await expectLater(
        readCurrentMeeting(reader, StoreReadQueries.preference('fixture')),
        throwsA(same(reader.readError)),
      );
    },
  );
}
