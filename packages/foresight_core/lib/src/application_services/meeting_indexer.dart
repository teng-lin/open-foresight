import 'dart:async';
import 'dart:convert';

import '../domain.dart';
import '../cancellation.dart';
import '../persistence/capture_queries.dart';
import '../persistence/meeting_index_jobs.dart';
import '../persistence/meeting_queries.dart';
import '../persistence/meeting_transcript_projection.dart';
import '../rpc_error.dart';
import '../store.dart';
import 'capture_activity.dart';

final class _MeetingIndexRun {
  _MeetingIndexRun(this.meeting, this.epoch, this.workspace);
  final int meeting, workspace;
  final String epoch;
  final done = Completer<void>();
}

/// One producer per meeting owns durable work independently of its subscribers.
/// Repeated live/final notifications coalesce into the current producer; only
/// bounded dirty rows/pieces are read and sent. Paused jobs remain service work.
final class MeetingIndexer {
  MeetingIndexer({
    required this.domain,
    required this.meetings,
    required this.capture,
    required this.changed,
  }) : queries = CaptureQueries(domain.store, meetings),
       jobs = MeetingIndexJobs(
         domain.store.db,
         workspaceEpoch: () => domain.store.workspaceEpoch,
       ),
       projection = MeetingTranscriptProjection(domain.store);
  final Domain domain;
  final MeetingQueries meetings;
  final CaptureActivity capture;
  final CaptureQueries queries;
  final MeetingIndexJobs jobs;
  final MeetingTranscriptProjection projection;
  final void Function() changed;
  Store get store => domain.store;
  final _runs = <int, _MeetingIndexRun>{};
  final _allRuns = <_MeetingIndexRun>{};
  bool _closed = false, _recovering = false;
  Future<void>? _closing;
  bool get busy => _allRuns.isNotEmpty || _recovering;
  Map<String, int> get workMetrics => projection.metrics.snapshot;

  Future<void> scheduleFinalIndex(int id) => _request(id);
  Future<void> indexMeeting(int id, {bool Function()? current}) async {
    final producer = _request(id);
    if (domain.sourcesPaused) {
      // Preserve the historical paused-call admission contract. Durable intent
      // and the producer, rather than a caller Future, retain the work.
      producer.ignore();
      return;
    }
    await domain.awaitCurrent(producer, current);
  }

  Future<void> _request(int id) {
    queries.requireMeeting(id);
    final source = projection.source(id);
    if (source?.deleted == true) {
      throw RpcError(RpcErrorCode.notFound, 'Transcript source was deleted');
    }
    if (!projection.hasTranscript(id) && source == null) {
      return Future<void>.value();
    }
    final intent = jobs.request(
      id,
    ); // Synchronous even during orderly shutdown.
    if (_closed) return Future<void>.value();
    final existing = _runs[id];
    if (existing != null &&
        existing.epoch == intent.epoch &&
        existing.workspace == domain.workspaceGeneration) {
      return existing.done.future;
    }
    if (_allRuns.length >= 64) {
      throw RpcError(
        RpcErrorCode.busy,
        'Meeting indexing backlog is full; the saved intent will be retried',
      );
    }
    final run = _MeetingIndexRun(id, intent.epoch, domain.workspaceGeneration);
    _runs[id] = run;
    _allRuns.add(run);
    // Future.sync defers errors to the observed producer while keeping the
    // registration ahead of its first await and any service-idle observation.
    unawaited(
      Future<void>.sync(() => _produce(run)).then<void>(
        (_) {
          _settle(run);
        },
        onError: (Object error, StackTrace stack) {
          try {
            if (!domain.closed &&
                store.workspaceEpoch == run.epoch &&
                domain.workspaceGeneration == run.workspace &&
                projection.source(run.meeting)?.generated == true) {
              store.state(
                projection.sourceId(run.meeting),
                _closed ? 'pending' : 'failed',
                _closed
                    ? ''
                    : 'Transcript indexing could not complete; saved for retry.',
              );
            }
          } catch (_) {
            /* Keep the producer's original error if storage is unavailable. */
          }
          _settle(run, error, stack);
        },
      ),
    );
    // Background start/recovery is observed here; explicit subscribers still
    // receive the same original failure through this Future.
    run.done.future.ignore();
    changed();
    return run.done.future;
  }

  void _settle(_MeetingIndexRun run, [Object? error, StackTrace? stack]) {
    if (identical(_runs[run.meeting], run)) _runs.remove(run.meeting);
    _allRuns.remove(run);
    changed();
    if (error == null) {
      run.done.complete();
    } else {
      run.done.completeError(error, stack);
    }
  }

  bool _active(_MeetingIndexRun run) {
    if (_closed || domain.closed || !identical(_runs[run.meeting], run)) {
      return false;
    }
    try {
      return store.workspaceEpoch == run.epoch &&
          domain.workspaceGeneration == run.workspace &&
          projection.revision(run.meeting) != null &&
          projection.source(run.meeting)?.deleted != true;
    } catch (_) {
      return false;
    }
  }

  bool _generated(_MeetingIndexRun run) =>
      _active(run) && projection.source(run.meeting)?.generated == true;
  String _model() {
    final state = domain.helper.snapshot;
    return jsonEncode([
      state?.instanceId,
      state?.activeGeneration.toString(),
      state?.pendingGeneration.toString(),
      state?.model.writeToJson(),
    ]);
  }

  Future<void> _produce(_MeetingIndexRun run) async {
    final id = run.meeting;
    projection.ensureSource(id, run.epoch);
    projection.expire(id);
    var modelRestarts = 0;
    while (_active(run)) {
      await domain.waitForSourceWork(current: () => _active(run));
      if (!_active(run)) throw operationCancelled();
      final revision = projection.revision(id)!;
      final source = projection.source(id)!;
      if (!source.generated || !projection.mapped(id)) {
        if (source.state != 'indexed') {
          await domain.index(
            projection.sourceId(id),
            current: () => _active(run),
          );
        }
        if (!_active(run)) throw operationCancelled();
        if (projection.source(id)?.state != 'indexed') continue;
        jobs.complete(
          MeetingIndexIntent(meeting: id, epoch: run.epoch, revision: revision),
        );
        return;
      }
      if (domain.helper.snapshot?.pipeline == 'unconfigured' &&
          store.sourceQueries.model('embedding') == null) {
        return; // Retain durable pending intent until actual model readiness.
      }
      final token = _model();
      final cursor = await domain.transcriptCursor(
        projection.sourceId(id),
        current: () => _generated(run),
      );
      if (!_generated(run)) continue;
      var batch = projection.pending(id, run.epoch);
      if (projection.hasPending(id) && batch == null) projection.reset(id);
      if (batch != null &&
          !((cursor.revision == batch.request.expectedRevision) ||
              (cursor.exists &&
                  cursor.workspaceEpoch == run.epoch &&
                  cursor.revision == batch.request.revision))) {
        projection.reset(id);
        batch = null;
      }
      if ((!cursor.exists || cursor.workspaceEpoch != run.epoch) &&
          batch == null) {
        projection.reset(id);
      }
      if (batch == null &&
          cursor.revision.toInt() != projection.confirmedRevision(id)) {
        // A restored/replaced helper can retain a cursor older or newer than
        // this application's last confirmed transaction. Rebuild current
        // authoritative pieces instead of trusting stale acknowledgement bits.
        projection.reset(id);
      }
      batch ??= projection.prepare(id, run.epoch, cursor.revision.toInt());
      if (batch == null) {
        if (projection.unfinished(id)) continue;
        if (projection.complete(
          jobs,
          MeetingIndexIntent(meeting: id, epoch: run.epoch, revision: revision),
          source.revision,
        )) {
          return;
        }
        continue;
      }
      try {
        store.state(projection.sourceId(id), 'indexing');
        final result = await domain.applyTranscriptDelta(
          batch.request,
          current: () => _generated(run),
        );
        if (!_generated(run)) continue;
        if (token != _model()) {
          if (++modelRestarts > 3) {
            throw RpcError(
              RpcErrorCode.busy,
              'Embedding runtime changed repeatedly; transcript retained for retry',
            );
          }
          continue; // Exact persisted batch is checked on the new generation.
        }
        if (result.revision != batch.request.revision) {
          throw StateError('Helper acknowledged a different transcript cursor');
        }
        projection.acknowledge(id, run.epoch, batch);
      } on RpcError catch (error) {
        if (error.code == RpcErrorCode.cancelled &&
            _active(run) &&
            !_generated(run)) {
          continue;
        }
        rethrow;
      }
    }
    throw operationCancelled();
  }

  Future<void> recover() async {
    if (_closed || _recovering) return;
    _recovering = true;
    changed();
    try {
      var after = 0;
      while (!_closed) {
        // A helper database can be independently restored/removed. Verify its
        // cursor even when the app's previous successful revision is current;
        // unchanged cursors cause no transcript body reads or embeddings.
        final pending = jobs.recover(
          limit: 32,
          afterMeeting: after,
          verifyCompleted: true,
        );
        if (pending.isEmpty) break;
        after = pending
            .map((item) => item.meeting)
            .reduce((a, b) => a > b ? a : b);
        await Future.wait(
          pending.map((intent) async {
            try {
              await _request(intent.meeting);
            } catch (_) {
              /* Durable intent remains; no hot retry or false ack. */
            }
          }),
        );
      }
    } finally {
      _recovering = false;
      changed();
    }
  }

  void stop() {
    _closed = true;
    domain.checkCancellations();
  }

  Future<void> close() => _closing ??= Future<void>.sync(() async {
    stop();
    await Future.wait(
      _allRuns.map((run) => run.done.future.catchError((Object _) {})).toList(),
    );
  });
}
