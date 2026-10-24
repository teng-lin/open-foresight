import 'package:foresight_core/src/persistence/meeting_transcript_projection.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/generated/transcript_index.pb.dart' as wire;
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart' as rag;
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/transcript_index_service.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class ProjectionRag extends rag.RagServiceBase {
  int deletions = 0;
  @override
  Future<rag.IndexResponse> indexDocument(
    ServiceCall call,
    rag.IndexRequest request,
  ) async => throw GrpcError.unimplemented(
    'Manual indexing unavailable in this fixture',
  );
  @override
  Future<rag.DeleteResponse> deleteDocument(
    ServiceCall call,
    rag.DeleteRequest request,
  ) async {
    deletions++;
    return rag.DeleteResponse(success: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late Store store;
  late Helper helper;
  late Domain domain;
  late Application app;
  late Server server;
  late ControlledTranscriptIndex peer;
  late ProjectionRag ragPeer;
  late int meeting;
  late String socket;
  String getId() => 'meeting-$meeting';
  void open() {
    store = Store('${root.path}/application.db');
    helper = Helper(socket, '${root.path}/helper', manageProcess: false)
      ..snapshot = control.State(
        instanceId: 'producer-test',
        model: control.ModelIdentity(modelDigest: 'embedding-fixture'),
      );
    domain = Domain(store, helper);
    app = Application(domain);
  }

  Future<void> close() async {
    await app.close();
    domain.close();
    await domain.drain();
    await helper.close();
    store.close();
  }

  int append(String text, {String source = 'microphone'}) {
    store.transcript(meeting, text, true, 10, 20, source);
    return store.rows('SELECT max(id) AS id FROM transcript').single['id']
        as int;
  }

  String indexedText() =>
      (peer.pieces[getId()]?.values ?? <wire.TranscriptSegment>[])
          .map((piece) => piece.text)
          .join('\n');
  setUp(() async {
    root = createTestTempDirectorySync('projection-');
    socket = '${root.path}/peer.sock';
    peer = ControlledTranscriptIndex();
    ragPeer = ProjectionRag();
    server = Server.create(services: [peer, ragPeer]);
    await server.serve(
      address: InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
    );
    open();
    meeting = store.meeting('Incremental capture');
  });
  setUp(() {
    addTearDown(() async {
      await close();
      await server.shutdown();
    });
  });

  test(
    'row made interim before projection retires its empty journal without a helper mutation',
    () async {
      append('Initial indexed evidence');
      await app.indexMeeting(meeting);
      final requests = peer.requests.length;
      final removed = append('Removed before indexing');
      store.db.execute('UPDATE transcript SET final=0 WHERE id=?', [removed]);
      final projection = MeetingTranscriptProjection(store);
      final cursor = peer.cursors[getId()]!;
      // Check synchronously before entering the producer: a regressed journal
      // cleanup fails this assertion instead of starving the runner's watchdog.
      expect(
        projection.prepare(
          meeting,
          store.workspaceEpoch,
          cursor.revision.toInt(),
        ),
        isNull,
      );
      expect(projection.unfinished(meeting), false);
      await app.indexMeeting(meeting).timeout(const Duration(seconds: 5));
      expect(peer.requests, hasLength(requests));
      expect(indexedText(), contains('Initial indexed evidence'));
      expect(indexedText(), isNot(contains('Removed before indexing')));
      expect(store.rows('SELECT * FROM meeting_index_jobs'), isEmpty);
    },
  );

  test(
    'producer append work and serialization scale linearly without source history',
    () async {
      Map<String, int>? at64;
      for (var i = 0; i < 128; i++) {
        append('segment ${i.toString().padLeft(3, '0')} ${'speech ' * 16}');
        await app.indexMeeting(meeting);
        expect(store.sourceQueries.summaries().single.state, 'indexed');
        if (i == 0) store.db.execute('UPDATE source_details SET changed=1');
        if (i == 1) {
          expect(
            store.rows('SELECT changed FROM source_details').single['changed'],
            greaterThan(1),
          );
        }
        if (i == 63) at64 = {...app.meetingIndexWork};
      }
      final at128 = app.meetingIndexWork;
      for (final metric in [
        'transcript_rows_read',
        'transcript_bytes_read',
        'piece_rows_written',
        'canonical_bytes',
      ]) {
        expect(
          at128[metric]! / at64![metric]!,
          lessThanOrEqualTo(2.5),
          reason: '$metric: $at64 -> $at128',
        );
      }
      expect(at128['transcript_rows_read'], 128);
      expect(at128['piece_rows_written'], 128);
      expect(peer.embeddedChunks, 128);
      expect(
        store.rows('SELECT content,generated,revision FROM sources').single,
        containsPair('content', ''),
      );
      expect(
        store.rows('SELECT generated FROM sources').single['generated'],
        1,
      );
      expect(store.contentHistory.revisions('sources', getId()), isEmpty);
      final reader = Store.readOnly(store.path);
      try {
        final body = reader.sourceQueries.source(getId())!.content;
        expect(body, contains('segment 000'));
        expect(body, contains('segment 127'));
        expect(body, indexedText());
        expect(
          store.contentHistory.row('sources', getId()).single['content'],
          body,
        );
        expect(reader.sourceQueries.search('segment 127'), contains(getId()));
      } finally {
        reader.close();
      }
      print(
        'APP_LINEARITY N64=$at64 N128=$at128 wire=${peer.receivedBytes} embedded=${peer.embeddedBytes}',
      );
    },
  );

  test('large UTF8 imported rows split into bounded stable pieces', () async {
    append('🦊' * 20000, source: 'imported');
    await app.indexMeeting(meeting);
    final pieces = peer.requests.expand((request) => request.upserts).toList();
    expect(pieces.length, 2);
    expect(
      pieces.every((piece) => utf8.encode(piece.text).length <= 65536),
      true,
    );
    expect(
      pieces.map((piece) => piece.text).join(),
      store.sourceQueries.source(getId())!.content,
    );
    final before = peer.embeddedBytes;
    await app.indexMeeting(meeting);
    expect(peer.embeddedBytes, before);
    expect(app.meetingIndexWork['transcript_rows_read'], 1);
  });

  test(
    'lost acknowledgement replays identity-only outbox after restart exactly once',
    () async {
      final text = 'private transcript canary 7cfc9a';
      append(text);
      peer.failAfterCommitOnce = true;
      await expectLater(app.indexMeeting(meeting), throwsA(isA<GrpcError>()));
      final batch =
          store
                  .rows('SELECT metadata FROM meeting_index_batches')
                  .single['metadata']
              as String;
      expect(batch, isNot(contains(text)));
      expect(batch, isNot(contains('private transcript')));
      final first = peer.requests.single.writeToBuffer();
      final embedded = peer.embeddedBytes;
      await close();
      open();
      await app.recoverMeetingIndexes();
      expect(peer.requests, hasLength(2));
      expect(peer.requests.last.writeToBuffer(), first);
      expect(peer.embeddedBytes, embedded);
      expect(store.rows('SELECT * FROM meeting_index_batches'), isEmpty);
      expect(store.rows('SELECT * FROM meeting_index_jobs'), isEmpty);
      expect(store.sourceQueries.source(getId())!.state, 'indexed');
    },
  );

  test(
    'local acknowledgement write failure retains exact committed-helper batch for retry',
    () async {
      append('committed transcript despite local acknowledgement failure');
      store.db.execute(
        "CREATE TRIGGER reject_ack BEFORE UPDATE OF acknowledged ON meeting_index_segments WHEN NEW.acknowledged=1 BEGIN SELECT RAISE(ABORT,'controlled ack storage fault'); END",
      );
      await expectLater(app.indexMeeting(meeting), throwsA(anything));
      final request = peer.requests.single.writeToBuffer(),
          embedded = peer.embeddedBytes;
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(1));
      expect(store.rows('SELECT * FROM meeting_index_batches'), hasLength(1));
      expect(
        store
            .rows('SELECT acknowledged FROM meeting_index_segments')
            .single['acknowledged'],
        0,
      );
      store.db.execute('DROP TRIGGER reject_ack');
      await app.indexMeeting(meeting);
      expect(peer.requests.last.writeToBuffer(), request);
      expect(peer.embeddedBytes, embedded);
      expect(store.rows('SELECT * FROM meeting_index_jobs'), isEmpty);
      expect(store.sourceQueries.source(getId())!.state, 'indexed');
    },
  );

  test(
    'helper reset or restored older cursor reconstructs acknowledged pieces',
    () async {
      append('first authoritative segment');
      await app.indexMeeting(meeting);
      final old = wire.TranscriptCursor.fromBuffer(
        peer.cursors[getId()]!.writeToBuffer(),
      );
      append('second authoritative segment');
      await app.indexMeeting(meeting);
      peer.cursors[getId()] = old;
      peer.pieces[getId()]!.removeWhere(
        (key, value) => value.text.contains('second'),
      );
      await app.indexMeeting(meeting);
      expect(peer.requests.last.reset, true);
      expect(indexedText(), contains('first authoritative'));
      expect(indexedText(), contains('second authoritative'));
      peer.cursors.clear();
      peer.pieces.clear();
      await app.recoverMeetingIndexes();
      expect(peer.requests.last.reset, true);
      expect(peer.pieces[getId()], hasLength(2));
      expect(
        app.meetingIndexWork['transcript_rows_read'],
        2,
        reason:
            'Recovery reuses current pieces, without rereading authoritative bodies',
      );
    },
  );

  test(
    'edits and deletes erase stale derived text and preserve current citations',
    () async {
      final first = append('erase-me-canary');
      final second = append('retain-me');
      await app.indexMeeting(meeting);
      store.db.execute('UPDATE transcript SET text=? WHERE id=?', [
        'edited current text',
        first,
      ]);
      expect(
        store.rows(
          "SELECT * FROM meeting_index_segments WHERE text LIKE '%erase-me-canary%'",
        ),
        isEmpty,
      );
      await app.indexMeeting(meeting);
      expect(indexedText(), isNot(contains('erase-me-canary')));
      expect(indexedText(), contains('edited current text'));
      expect(peer.requests.last.deletes, isNotEmpty);
      store.db.execute('DELETE FROM transcript WHERE id=?', [second]);
      await app.indexMeeting(meeting);
      expect(indexedText(), isNot(contains('retain-me')));
      expect(
        store.sourceQueries.source(getId())!.content,
        contains('edited current text'),
      );
      expect(store.rows('SELECT * FROM meeting_index_deletes'), isEmpty);
      expect(store.contentHistory.revisions('sources', getId()), isEmpty);
    },
  );

  test(
    'manual source ownership survives producer notifications and deletion never resurrects',
    () async {
      append('original transcript');
      await app.indexMeeting(meeting);
      store.importText(
        'Manual transcript',
        'user owned replacement',
        'text/plain',
        'user edit; meeting:$meeting',
        id: getId(),
      );
      expect(store.rows('SELECT * FROM meeting_index_segments'), isEmpty);
      // A manual source uses the ordinary index API, whose peer is deliberately
      // unavailable here. Its failure must not replace its authoritative body.
      await expectLater(app.indexMeeting(meeting), throwsA(isA<GrpcError>()));
      expect(
        store.sourceQueries.source(getId())!.content,
        'user owned replacement',
      );
      store.tombstone(getId());
      await app.recoverMeetingIndexes();
      expect(store.rows('SELECT * FROM meeting_index_jobs'), isEmpty);
      expect(store.rows('SELECT * FROM meeting_index_batches'), isEmpty);
      await close();
      open();
      await app.recoverMeetingIndexes();
      expect(store.sourceQueries.source(getId()), isNull);
      expect(
        store.rows('SELECT deleted FROM sources WHERE id=?', [
          getId(),
        ]).single['deleted'],
        1,
      );
    },
  );

  test(
    'cancellation keeps durable source work pending rather than failed',
    () async {
      append('retry after cancellation');
      peer.beforeApply = (call, request) async =>
          throw GrpcError.cancelled('Controlled peer cancellation');
      await expectLater(app.indexMeeting(meeting), throwsA(isA<GrpcError>()));
      expect(store.sourceQueries.source(getId())!.state, 'pending');
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(1));
    },
  );

  test(
    'tombstone cancellation never overwrites deletion state with failed',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      peer.beforeApply = (call, request) async {
        entered.complete();
        await release.future;
      };
      append('deleted during indexing');
      final work = app.indexMeeting(meeting);
      final cancelled = expectLater(
        work,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await entered.future;
      store.db.execute('CREATE TEMP TABLE tombstone_states(state TEXT)');
      store.db.execute(
        "CREATE TEMP TRIGGER audit_tombstone_state AFTER UPDATE OF state ON sources WHEN NEW.id='${getId()}' BEGIN INSERT INTO tombstone_states VALUES(NEW.state); END",
      );
      final deletion = domain.delete(getId());
      await cancelled;
      expect(
        store.rows("SELECT * FROM tombstone_states WHERE state='failed'"),
        isEmpty,
      );
      release.complete();
      await deletion;
      expect(
        store
            .rows('SELECT state FROM tombstone_states')
            .map((row) => row['state']),
        ['deleting', 'deleted'],
      );
      expect(
        store.sourceQueries.source(getId(), includeDeleted: true)!.state,
        'deleted',
      );
      expect(ragPeer.deletions, 1);
      await domain.reconcile();
      expect(ragPeer.deletions, 1);
    },
  );

  test(
    'saved delta requires matching workspace epoch before cursor reuse',
    () async {
      append('first segment');
      await app.indexMeeting(meeting);
      append('second segment');
      peer.beforeApply = (call, request) async =>
          throw GrpcError.unavailable('Controlled pre-commit failure');
      await expectLater(app.indexMeeting(meeting), throwsA(isA<GrpcError>()));
      expect(store.rows('SELECT * FROM meeting_index_batches'), hasLength(1));
      peer.beforeApply = null;
      peer.cursors[getId()]!.workspaceEpoch = 'independently-restored-epoch';
      final before = peer.requests.length;
      await app.indexMeeting(meeting);
      expect(peer.requests.skip(before), hasLength(1));
      expect(peer.requests.last.reset, true);
      expect(peer.cursors[getId()]!.workspaceEpoch, store.workspaceEpoch);
      expect(
        indexedText(),
        allOf(contains('first segment'), contains('second segment')),
      );
      expect(store.rows('SELECT * FROM meeting_index_jobs'), isEmpty);
    },
  );

  test(
    'ABORTED cursor race reconciles with a bounded current-data reset',
    () async {
      append('current authoritative segment');
      var raced = false;
      peer.beforeApply = (call, request) async {
        if (!raced) {
          raced = true;
          peer.cursors[getId()] = wire.TranscriptCursor(
            exists: true,
            workspaceEpoch: store.workspaceEpoch,
            revision: request.expectedRevision + 7,
          );
        }
      };
      await app.indexMeeting(meeting);
      expect(peer.requests, hasLength(2));
      expect(peer.requests.last.reset, true);
      expect(peer.requests.last.expectedRevision.toInt(), 7);
      expect(indexedText(), contains('current authoritative segment'));
      expect(store.sourceQueries.source(getId())!.state, 'indexed');
    },
  );

  test(
    'repeated ABORTED cursor races stop after three reconciliation attempts',
    () async {
      append('retained after repeated cursor races');
      peer.beforeApply = (call, request) async =>
          throw GrpcError.aborted('Controlled persistent cursor race');
      await expectLater(
        app.indexMeeting(meeting),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      expect(peer.requests, hasLength(4));
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(peer.requests, hasLength(4));
    },
  );

  test(
    'paused durable producer counts as service work and closes without helper admission',
    () async {
      append('held until model resumes');
      domain.pauseSources();
      await app.indexMeeting(meeting);
      expect(app.backgroundBusy, true);
      expect(peer.requests, isEmpty);
      await app.close();
      expect(app.backgroundBusy, false);
      expect(peer.requests, isEmpty);
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(1));
    },
  );

  test(
    'unconfigured helper retains pending work for model-ready source replay',
    () async {
      append('ready after model configuration');
      await app.indexMeeting(meeting);
      peer.cursors.clear();
      peer.pieces.clear();
      helper.snapshot!.pipeline = 'unconfigured';
      await app.indexMeeting(meeting);
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(1));
      expect(store.sourceQueries.source(getId())!.state, 'pending');
      helper.snapshot!.pipeline = 'ready';
      await domain.indexPendingSources();
      expect(peer.pieces[getId()], hasLength(1));
      expect(store.rows('SELECT * FROM meeting_index_jobs'), isEmpty);
      expect(store.sourceQueries.source(getId())!.state, 'indexed');
      expect(app.meetingIndexWork['transcript_rows_read'], 1);
    },
  );

  test(
    'close cancels owned RPC while preserving durable intent and joins settlement',
    () async {
      final entered = Completer<void>(), finishPeer = Completer<void>();
      peer.beforeApply = (call, request) async {
        entered.complete();
        await finishPeer.future;
      };
      append('unfinished durable work');
      final work = app.indexMeeting(meeting);
      final rejected = expectLater(work, throwsA(anything));
      await entered.future;
      await app.close().timeout(const Duration(seconds: 5));
      await rejected;
      await eventually(() => peer.calls.single.isCanceled);
      expect(domain.mutating, 0);
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(1));
      expect(store.sourceQueries.source(getId())!.state, 'pending');
      finishPeer.complete();
    },
  );

  test(
    'journal compaction bounds identity retention and reconstructs every row',
    () async {
      store.db.execute('BEGIN');
      for (var i = 0; i < 4097; i++) {
        append('bounded row $i');
      }
      store.db.execute('COMMIT');
      final progress = store
          .rows('SELECT * FROM meeting_index_progress')
          .single;
      expect(progress['reset_required'], 1);
      expect(progress['pending_changes'], 0);
      expect(store.rows('SELECT * FROM meeting_transcript_changes'), isEmpty);
      await app.indexMeeting(meeting);
      expect(peer.pieces[getId()], hasLength(4097));
      expect(app.meetingIndexWork['transcript_rows_read'], 4097);
      expect(store.rows('SELECT * FROM meeting_transcript_changes'), isEmpty);
      expect(
        store
            .rows(
              'SELECT pending_changes,pending_deletes FROM meeting_index_progress',
            )
            .single,
        {'pending_changes': 0, 'pending_deletes': 0},
      );
    },
  );

  for (final invalid in ['malformed', 'expired']) {
    test(
      '$invalid saved metadata resets from current authoritative pieces',
      () async {
        append('current private payload');
        peer.failAfterCommitOnce = true;
        await expectLater(app.indexMeeting(meeting), throwsA(isA<GrpcError>()));
        if (invalid == 'malformed') {
          store.db.execute(
            "UPDATE meeting_index_batches SET metadata='invalid JSON'",
          );
        } else {
          store.db.execute('UPDATE meeting_index_batches SET created=0');
        }
        await app.indexMeeting(meeting);
        expect(peer.requests.last.reset, true);
        expect(indexedText(), contains('current private payload'));
        expect(store.rows('SELECT * FROM meeting_index_batches'), isEmpty);
        expect(app.meetingIndexWork['transcript_rows_read'], 1);
      },
    );
  }

  for (final erase in ['edit', 'delete']) {
    test(
      'transcript $erase erases managed snapshots and old cache/WAL bytes',
      () async {
        const canary = 'removed-transcript-privacy-canary-4f687';
        final id = append(canary);
        await app.indexMeeting(meeting);
        final snapshot = store.migrationBackups.create(
          store.db,
          Store.schemaVersion,
        );
        final copy = File(
          '${store.migrationBackups.directoryPath}/${snapshot.name}',
        );
        expect(latin1.decode(copy.readAsBytesSync()), contains(canary));
        if (erase == 'edit') {
          store.db.execute('UPDATE transcript SET text=? WHERE id=?', [
            'current replacement',
            id,
          ]);
        } else {
          store.db.execute('DELETE FROM transcript WHERE id=?', [id]);
        }
        expect(store.preference('internal.backupErasurePending'), '1');
        expect(
          store.rows(
            "SELECT * FROM meeting_index_segments WHERE text LIKE '%$canary%'",
          ),
          isEmpty,
        );
        await app.indexMeeting(meeting);
        await eventually(
          () => !store.privacyMaintenancePending,
          timeout: const Duration(seconds: 8),
        );
        expect(copy.existsSync(), false);
        expect(
          store.migrationBackups.snapshots(
            supportedVersion: Store.schemaVersion,
          ),
          isEmpty,
        );
        for (final path in [store.path, '${store.path}-wal']) {
          final file = File(path);
          if (file.existsSync()) {
            expect(
              latin1.decode(file.readAsBytesSync()),
              isNot(contains(canary)),
            );
          }
        }
      },
    );
  }
}
