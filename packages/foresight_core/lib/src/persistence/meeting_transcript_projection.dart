import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fixnum/fixnum.dart';

import '../generated/transcript_index.pb.dart' as wire;
import '../meeting_speakers.dart';
import '../meeting_workflow_store.dart';
import '../rpc_error.dart';
import '../store.dart';
import 'meeting_index_jobs.dart';

final class MeetingIndexMetrics {
  int transcriptRowsRead = 0, transcriptBytesRead = 0;
  int pieceRowsWritten = 0, serializedBytes = 0, batches = 0;
  Map<String, int> get snapshot => {
    'transcript_rows_read': transcriptRowsRead,
    'transcript_bytes_read': transcriptBytesRead,
    'piece_rows_written': pieceRowsWritten,
    'canonical_bytes': serializedBytes,
    'batches': batches,
  };
}

final class TranscriptSourceState {
  TranscriptSourceState(
    this.revision,
    this.state,
    this.generated,
    this.deleted,
  );
  final int revision;
  final String state;
  final bool generated, deleted;
}

final class TranscriptBatch {
  TranscriptBatch(this.request, this.metadata);
  final wire.TranscriptDelta request;
  final Map<String, Object?> metadata;
}

/// SQLite owns authoritative transcript rows and current derived pieces. This
/// repository never writes a full transcript source body. The durable outbox
/// contains bounded identities/hashes only and is validated before every retry.
final class MeetingTranscriptProjection {
  MeetingTranscriptProjection(this.store, {MeetingIndexMetrics? metrics})
    : metrics = metrics ?? MeetingIndexMetrics();
  final Store store;
  final MeetingIndexMetrics metrics;
  static const maxPieces = 64, maxBatchBytes = 512 * 1024;
  static const journalAge = Duration(hours: 24);
  String sourceId(int meeting) => 'meeting-$meeting';
  int? revision(int meeting) =>
      store.rows('SELECT revision FROM meetings WHERE id=?', [
            meeting,
          ]).firstOrNull?['revision']
          as int?;
  TranscriptSourceState? source(int meeting) {
    final row = store.rows(
      'SELECT revision,state,generated,locally_edited,deleted FROM sources WHERE id=?',
      [sourceId(meeting)],
    ).firstOrNull;
    return row == null
        ? null
        : TranscriptSourceState(
            row['revision'] as int,
            row['state'] as String,
            row['generated'] == 1 && row['locally_edited'] == 0,
            row['deleted'] != 0,
          );
  }

  bool hasTranscript(int meeting) => store.rows(
    'SELECT 1 FROM transcript WHERE meeting_id=? AND final=1 LIMIT 1',
    [meeting],
  ).isNotEmpty;
  bool mapped(int meeting) => store.rows(
    'SELECT 1 FROM meeting_transcript_sources WHERE meeting_id=?',
    [meeting],
  ).isNotEmpty;

  void ensureSource(int meeting, String epoch) {
    store.workflowTransaction(() {
      final existing = source(meeting);
      if (existing?.deleted == true) {
        throw RpcError(RpcErrorCode.notFound, 'Transcript source was deleted');
      }
      if (existing != null && !existing.generated) return;
      // Some historical profiles retain a source without its original capture
      // rows. Keep that committed body until actual transcript rows are present.
      if (existing != null && !mapped(meeting) && !hasTranscript(meeting)) {
        return;
      }
      if (existing == null) {
        store.importText(
          'Meeting $meeting transcript',
          '',
          'text/plain',
          'meeting:$meeting',
          id: sourceId(meeting),
          generated: true,
        );
      }
      store.db.execute(
        'INSERT OR IGNORE INTO meeting_transcript_sources VALUES(?,?)',
        [sourceId(meeting), meeting],
      );
      if (store.db.updatedRows != 0 && existing != null) {
        // A historical stored body just changed to authoritative row projection.
        // Revisions/citations must become pending before any helper RPC can ack.
        store.db.execute(
          "UPDATE sources SET revision=revision+1,state='pending',error='' WHERE id=? AND generated=1 AND deleted=0",
          [sourceId(meeting)],
        );
        store.db.execute(
          'UPDATE source_details SET changed=? WHERE source_id=?',
          [DateTime.now().millisecondsSinceEpoch, sourceId(meeting)],
        );
      }
      // One-time conversion of an older generated full-body source. Its visible
      // content is already provided by source_contents, not this storage cell.
      store.db.execute(
        "UPDATE sources SET content='' WHERE id=? AND generated=1 AND content!=''",
        [sourceId(meeting)],
      );
      store.db.execute(
        'INSERT OR IGNORE INTO meeting_index_progress(meeting_id,workspace_epoch) VALUES(?,?)',
        [meeting, epoch],
      );
      store.db.execute(
        'UPDATE meeting_index_progress SET workspace_epoch=?,reset_required=1 WHERE meeting_id=? AND workspace_epoch!=?',
        [epoch, meeting, epoch],
      );
    });
  }

  void expire(int meeting) {
    final cutoff = DateTime.now().subtract(journalAge).millisecondsSinceEpoch;
    final stale = store.rows(
      'SELECT 1 FROM meeting_index_batches WHERE meeting_id=? AND created<? UNION ALL SELECT 1 FROM meeting_transcript_changes WHERE meeting_id=? AND changed<? UNION ALL SELECT 1 FROM meeting_index_deletes WHERE meeting_id=? AND created<? LIMIT 1',
      [meeting, cutoff, meeting, cutoff, meeting, cutoff],
    );
    if (stale.isEmpty) return;
    reset(meeting);
  }

  void reset(int meeting) => store.workflowTransaction(() {
    store.db.execute(
      'UPDATE meeting_index_progress SET reset_required=1,seeding=1,seed_after_id=0 WHERE meeting_id=?',
      [meeting],
    );
    store.db.execute('DELETE FROM meeting_index_batches WHERE meeting_id=?', [
      meeting,
    ]);
    store.db.execute(
      'DELETE FROM meeting_transcript_changes WHERE meeting_id=?',
      [meeting],
    );
    store.db.execute('DELETE FROM meeting_index_deletes WHERE meeting_id=?', [
      meeting,
    ]);
  });
  bool needsReset(int meeting) =>
      store.rows(
        'SELECT reset_required FROM meeting_index_progress WHERE meeting_id=?',
        [meeting],
      ).single['reset_required'] !=
      0;

  int confirmedRevision(int meeting) =>
      store.rows(
            'SELECT confirmed_revision FROM meeting_index_progress WHERE meeting_id=?',
            [meeting],
          ).single['confirmed_revision']
          as int;

  /// Reconstruct missing projection work in bounded pages. A point lookup in the
  /// per-transcript index avoids rereading bodies of already projected rows.
  void seedMissing(int meeting) {
    final progress = store.rows(
      'SELECT seeding,seed_after_id FROM meeting_index_progress WHERE meeting_id=?',
      [meeting],
    ).single;
    if (progress['seeding'] == 0) return;
    final page = store.rows(
      'SELECT id FROM transcript WHERE meeting_id=? AND final=1 AND id>? ORDER BY id LIMIT 32',
      [meeting, progress['seed_after_id']],
    );
    for (final row in page) {
      store.db.execute(
        'INSERT OR IGNORE INTO meeting_transcript_changes(meeting_id,transcript_id,changed) SELECT ?,?,? WHERE NOT EXISTS(SELECT 1 FROM meeting_index_segments WHERE transcript_id=?)',
        [meeting, row['id'], DateTime.now().millisecondsSinceEpoch, row['id']],
      );
    }
    store.db.execute(
      'UPDATE meeting_index_progress SET seed_after_id=?,seeding=? WHERE meeting_id=?',
      [
        page.isEmpty ? progress['seed_after_id'] : page.last['id'],
        page.length < 32 ? 0 : 1,
        meeting,
      ],
    );
  }

  void project(int meeting) {
    final changed = store.rows(
      'SELECT transcript_id,version FROM meeting_transcript_changes WHERE meeting_id=? AND projected=0 ORDER BY transcript_id LIMIT 32',
      [meeting],
    );
    var projectedBytes = 0;
    for (final change in changed) {
      final id = change['transcript_id'] as int;
      final length = store.rows(
        'SELECT length(CAST(text AS BLOB)) AS bytes FROM transcript WHERE id=? AND meeting_id=? AND final=1',
        [id, meeting],
      ).firstOrNull;
      if (length != null && (length['bytes'] as int) > 16 * 1024 * 1024) {
        throw RpcError(
          RpcErrorCode.invalidArgument,
          'Transcript row exceeds the 16 MiB indexing limit',
        );
      }
      final rowBytes = (length?['bytes'] as int?) ?? 0;
      if (projectedBytes != 0 && projectedBytes + rowBytes > 1024 * 1024) break;
      projectedBytes += rowBytes;
      final row = store.rows(
        'SELECT text,start_ms,end_ms,source FROM transcript WHERE id=? AND meeting_id=? AND final=1',
        [id, meeting],
      ).firstOrNull;
      store.workflowTransaction(() {
        if (row != null) {
          final text = row['text'] as String? ?? '';
          metrics.transcriptRowsRead++;
          metrics.transcriptBytesRead += utf8.encode(text).length;
          final speaker = MeetingSpeaker.fromSource(
            row['source'] as String? ?? '',
          );
          final channel = switch (speaker) {
            MeetingSpeaker.microphone => 0,
            MeetingSpeaker.remote => 1,
            MeetingSpeaker.unknown => 2,
          };
          final bytes = utf8.encode(
            '[${speaker.label} ${(row['start_ms'] as num?)?.toInt() ?? 0}–${(row['end_ms'] as num?)?.toInt() ?? 0} ms] $text',
          );
          var offset = 0, ordinal = 0;
          while (offset < bytes.length) {
            var end = (offset + 65536).clamp(0, bytes.length);
            while (end < bytes.length && bytes[end] & 0xc0 == 0x80) {
              end--;
            }
            final piece = utf8.decode(bytes.sublist(offset, end));
            final digest = sha256.convert(utf8.encode(piece)).toString();
            store.db.execute(
              'INSERT OR IGNORE INTO meeting_index_segments(meeting_id,transcript_id,channel,ordinal,text,digest) VALUES(?,?,?,?,?,?)',
              [meeting, id, channel, ordinal++, piece, digest],
            );
            if (store.db.updatedRows != 0) metrics.pieceRowsWritten++;
            offset = end;
          }
        }
        store.db.execute(
          'UPDATE meeting_transcript_changes SET projected=1 WHERE meeting_id=? AND transcript_id=? AND version=?',
          [meeting, id, change['version']],
        );
      });
    }
  }

  String _digest(wire.TranscriptDelta request) {
    final bytes = request.writeToBuffer();
    metrics.serializedBytes += bytes.length;
    return sha256.convert(bytes).toString();
  }

  wire.TranscriptKey _key(int id, int channel) => wire.TranscriptKey(
    segmentId: Int64(id),
    channel: wire.TranscriptKey_Channel.valueOf(channel)!,
  );

  TranscriptBatch? pending(int meeting, String epoch) {
    final row = store.rows(
      'SELECT metadata FROM meeting_index_batches WHERE meeting_id=? AND workspace_epoch=?',
      [meeting, epoch],
    ).firstOrNull;
    if (row == null) return null;
    try {
      return _restorePending(meeting, epoch, row['metadata'] as String);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on RangeError {
      return null;
    }
  }

  TranscriptBatch? _restorePending(int meeting, String epoch, String encoded) {
    final metadata = Map<String, Object?>.from(jsonDecode(encoded) as Map);
    final expectedRevision = metadata['expected'] as int;
    final nextRevision = metadata['revision'] as int;
    final upserts = metadata['upserts'] as List;
    final deletes = metadata['deletes'] as List;
    if (expectedRevision < 0 ||
        nextRevision != expectedRevision + 1 ||
        upserts.length > maxPieces ||
        deletes.length > maxPieces ||
        metadata['reset'] is! bool) {
      return null;
    }
    final request = wire.TranscriptDelta(
      documentId: sourceId(meeting),
      workspaceEpoch: epoch,
      expectedRevision: Int64(expectedRevision),
      revision: Int64(nextRevision),
      reset: metadata['reset'] == true,
    );
    for (final raw in upserts) {
      final expected = Map<String, Object?>.from(raw as Map);
      final piece = store.rows(
        'SELECT id,channel,text,digest FROM meeting_index_segments WHERE meeting_id=? AND id=?',
        [meeting, expected['id']],
      ).firstOrNull;
      if (piece == null ||
          piece['digest'] != expected['digest'] ||
          piece['channel'] != expected['channel']) {
        return null;
      }
      request.upserts.add(
        wire.TranscriptSegment(
          key: _key(piece['id'] as int, piece['channel'] as int),
          text: piece['text'] as String,
        ),
      );
    }
    for (final raw in deletes) {
      final key = Map<String, Object?>.from(raw as Map);
      request.deletes.add(_key(key['id'] as int, key['channel'] as int));
    }
    if (_digest(request) != metadata['digest']) return null;
    return TranscriptBatch(request, metadata);
  }

  bool hasPending(int meeting) => store.rows(
    'SELECT 1 FROM meeting_index_batches WHERE meeting_id=?',
    [meeting],
  ).isNotEmpty;

  TranscriptBatch? prepare(int meeting, String epoch, int helperRevision) {
    return store.workflowTransaction(() {
      final reset = needsReset(meeting);
      if (reset) {
        store.db.execute(
          'UPDATE meeting_index_progress SET seeding=1,seed_after_id=0 WHERE meeting_id=?',
          [meeting],
        );
        store.db.execute(
          'UPDATE meeting_index_segments SET acknowledged=0 WHERE meeting_id=?',
          [meeting],
        );
        store.db.execute(
          'DELETE FROM meeting_index_deletes WHERE meeting_id=?',
          [meeting],
        );
      }
      seedMissing(meeting);
      project(meeting);
      // A row can become interim before its first projection. There is then no
      // helper mutation to acknowledge, but its projected journal must retire.
      _retireProjectedChanges(meeting);
      final request = wire.TranscriptDelta(
        documentId: sourceId(meeting),
        workspaceEpoch: epoch,
        expectedRevision: Int64(helperRevision),
        revision: Int64(helperRevision + 1),
        reset: reset,
      );
      final upserts = <Map<String, Object?>>[],
          deletes = <Map<String, Object?>>[];
      var bytes = 0;
      for (final piece in store.rows(
        'SELECT id,channel,text,digest FROM meeting_index_segments WHERE meeting_id=? AND acknowledged=0 ORDER BY id LIMIT ?',
        [meeting, maxPieces],
      )) {
        final text = piece['text'] as String;
        final size = utf8.encode(text).length;
        if (bytes + size > maxBatchBytes && upserts.isNotEmpty) break;
        request.upserts.add(
          wire.TranscriptSegment(
            key: _key(piece['id'] as int, piece['channel'] as int),
            text: text,
          ),
        );
        upserts.add({
          'id': piece['id'],
          'channel': piece['channel'],
          'digest': piece['digest'],
        });
        bytes += size;
      }
      for (final key in store.rows(
        'SELECT segment_id,channel FROM meeting_index_deletes WHERE meeting_id=? ORDER BY segment_id LIMIT ?',
        [meeting, maxPieces],
      )) {
        request.deletes.add(
          _key(key['segment_id'] as int, key['channel'] as int),
        );
        deletes.add({'id': key['segment_id'], 'channel': key['channel']});
      }
      if (!reset && upserts.isEmpty && deletes.isEmpty) return null;
      final requestBytes = request.writeToBuffer();
      final metadata = <String, Object?>{
        'expected': helperRevision,
        'revision': helperRevision + 1,
        'reset': reset,
        'upserts': upserts,
        'deletes': deletes,
        'digest': sha256.convert(requestBytes).toString(),
      };
      final encoded = jsonEncode(metadata);
      if (utf8.encode(encoded).length > 16384 ||
          requestBytes.length > 1024 * 1024) {
        throw StateError(
          'Transcript indexing batch exceeded its bounded contract',
        );
      }
      store.db.execute(
        'INSERT OR REPLACE INTO meeting_index_batches VALUES(?,?,?,?)',
        [meeting, epoch, encoded, DateTime.now().millisecondsSinceEpoch],
      );
      store.db.execute(
        'UPDATE meeting_index_progress SET reset_required=0 WHERE meeting_id=?',
        [meeting],
      );
      metrics.serializedBytes += requestBytes.length;
      metrics.batches++;
      return TranscriptBatch(request, metadata);
    });
  }

  void _retireProjectedChanges(int meeting) {
    store.db.execute(
      'DELETE FROM meeting_transcript_changes WHERE meeting_id=? AND projected=1 AND NOT EXISTS(SELECT 1 FROM meeting_index_segments p WHERE p.transcript_id=meeting_transcript_changes.transcript_id AND p.acknowledged=0)',
      [meeting],
    );
  }

  void acknowledge(int meeting, String epoch, TranscriptBatch batch) {
    if (store.workspaceEpoch != epoch) return;
    store.workflowTransaction(() {
      for (final key in batch.metadata['upserts'] as List) {
        store.db.execute(
          'UPDATE meeting_index_segments SET acknowledged=1 WHERE meeting_id=? AND id=? AND digest=?',
          [meeting, key['id'], key['digest']],
        );
      }
      for (final key in batch.metadata['deletes'] as List) {
        store.db.execute(
          'DELETE FROM meeting_index_deletes WHERE meeting_id=? AND segment_id=?',
          [meeting, key['id']],
        );
      }
      _retireProjectedChanges(meeting);
      store.db.execute(
        'DELETE FROM meeting_index_batches WHERE meeting_id=? AND workspace_epoch=?',
        [meeting, epoch],
      );
      store.db.execute(
        'UPDATE meeting_index_progress SET confirmed_revision=? WHERE meeting_id=? AND workspace_epoch=?',
        [batch.request.revision.toInt(), meeting, epoch],
      );
    });
  }

  bool unfinished(int meeting) => store.rows(
    'SELECT 1 FROM meeting_index_progress WHERE meeting_id=? AND seeding=1 UNION ALL SELECT 1 FROM meeting_transcript_changes WHERE meeting_id=? UNION ALL SELECT 1 FROM meeting_index_segments WHERE meeting_id=? AND acknowledged=0 UNION ALL SELECT 1 FROM meeting_index_deletes WHERE meeting_id=? LIMIT 1',
    [meeting, meeting, meeting, meeting],
  ).isNotEmpty;
  bool complete(
    MeetingIndexJobs jobs,
    MeetingIndexIntent intent,
    int sourceRevision,
  ) {
    return store.workflowTransaction(() {
      final current = source(intent.meeting);
      if (current == null ||
          current.deleted ||
          current.revision != sourceRevision ||
          revision(intent.meeting) != intent.revision ||
          unfinished(intent.meeting)) {
        return false;
      }
      store.db.execute(
        "UPDATE sources SET state='indexed',error='' WHERE id=? AND revision=? AND deleted=0",
        [sourceId(intent.meeting), sourceRevision],
      );
      jobs.complete(intent);
      return true;
    });
  }
}
