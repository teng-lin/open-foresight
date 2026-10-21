import 'dart:async';
import 'dart:convert';

import '../domain.dart';
import '../meeting_speakers.dart';
import '../persistence/capture_queries.dart';
import '../persistence/meeting_queries.dart';
import '../store.dart';
import 'capture_activity.dart';

typedef _MeetingIndexKey = ({
  int meeting,
  int revision,
  int workspace,
  String model,
});

/// Coalesces only identical active indexing. The Domain owns the actual source
/// queue and its cancellation/settlement, including pending paused sources.
final class MeetingIndexer {
  MeetingIndexer({
    required this.domain,
    required this.meetings,
    required this.capture,
    required this.changed,
  }) : queries = CaptureQueries(domain.store, meetings);
  final Domain domain;
  final MeetingQueries meetings;
  final CaptureQueries queries;
  final CaptureActivity capture;
  final void Function() changed;
  Store get store => domain.store;
  final _meetingIndexes = <_MeetingIndexKey, Future<void>>{};

  Future<void> indexMeeting(int id, {bool Function()? current}) async {
    queries.requireMeeting(id);
    final text = meetings
        .transcript(id, finalOnly: true)
        .map(
          (t) =>
              '[${MeetingSpeaker.fromSource(t.source).label} ${t.startMs}–${t.endMs} ms] ${t.text}',
        )
        .join('\n');
    if (text.trim().isEmpty) return;
    final existing = queries.source('meeting-$id');
    final unchanged = existing?.content == text && existing?.deleted == false;
    if (unchanged && existing?.state == 'indexed') return;
    final source = unchanged
        ? 'meeting-$id'
        : store.importText(
            'Meeting $id transcript',
            text,
            'text/plain',
            'meeting:$id',
            id: 'meeting-$id',
          );
    final revision = queries.source(source)!.revision;
    final snapshot = domain.helper.snapshot;
    final key = (
      meeting: id,
      revision: revision,
      workspace: domain.workspaceGeneration,
      model: jsonEncode([
        snapshot?.instanceId,
        snapshot?.activeGeneration.toString(),
        snapshot?.pendingGeneration.toString(),
        snapshot?.model.writeToJson(),
      ]),
    );
    // The live timer and Stop can queue the same finalized transcript while
    // imports are paused. Share only identical in-flight work: otherwise Resume
    // embeds it twice and immediately turns the first indexed result back into
    // indexing. New source/model/workspace generations still get their own job.
    final indexing = _meetingIndexes.putIfAbsent(
      key,
      () => _indexMeetingSource(key, source),
    );
    if (domain.sourcesPaused) {
      unawaited(
        indexing.catchError((Object e) {
          capture.state = 'Meeting indexing: $e';
          changed();
        }),
      );
    } else {
      await domain.awaitCurrent(indexing, current);
    }
  }

  Future<void> _indexMeetingSource(_MeetingIndexKey key, String source) async {
    try {
      await domain.index(source);
    } finally {
      // Removing the map entry returns an already observed task; it starts no work.
      // ignore: unawaited_futures
      _meetingIndexes.remove(key);
    }
  }
}
