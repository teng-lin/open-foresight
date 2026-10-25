import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'service_runtime_ports.dart';
import '../native.dart';
import '../persistence/meeting_queries.dart';
import '../reference_note_transcript_format.dart';
import '../rpc_error.dart';
import '../store.dart';
import '../summary_generator.dart';
import '../summary_output.dart';
import 'generation_coordinator.dart';

class _SummaryRun {
  _SummaryRun(this.requestId, this.runtime);
  final String requestId;
  final NativeRuntime runtime;
  String? child;
  final finished = Completer<void>();
  bool active = true, cancelled = false;
  String error = '';
  SummaryProgress progress = const SummaryProgress('planning');
  Map<String, Object?> get state => {
    for (final entry in progress.json.entries)
      if (active || entry.key != 'preview') entry.key: entry.value,
    'active': active,
    'cancelled': cancelled,
    'error': error,
  };
  void cancel() {
    if (!active) return;
    cancelled = true;
    if (child case final id?) runtime.cancel(requestId: id);
  }
}

/// Summary lifetime is independent of presentation state and other features.
/// The generation coordinator retains the shared resource through settlement.
final class SummaryCoordinator {
  SummaryCoordinator({
    required this.domain,
    required this.generation,
    required this.meetings,
    required this.modelDigest,
    required this.changed,
  });
  final SummaryWorkspace domain;
  final GenerationCoordinator generation;
  final MeetingQueries meetings;
  final String Function() modelDigest;
  final void Function() changed;
  Store get store => domain.store;
  final _summaries = <int, _SummaryRun>{};
  final _active = <_SummaryRun>{};
  bool _closed = false;
  Future<void>? _closing;
  bool get busy => _active.isNotEmpty;
  Map<String, Object?> get state => {
    for (final entry in _summaries.entries) '${entry.key}': entry.value.state,
  };

  void cancelMeeting(int id) => _summaries[id]?.cancel();
  void clear() {
    for (final run in _active) {
      run.cancel();
    }
    _summaries.clear();
  }

  void stop() {
    _closed = true;
    for (final run in _active) {
      run.cancel();
    }
  }

  Future<void> close() => _closing ??= Future.sync(() async {
    stop();
    await Future.wait(_active.map((run) => run.finished.future));
  });

  /// Cancellation belongs to the public request, including whichever native
  /// child is currently executing. A disconnected lease cannot cancel a peer.
  bool cancelSummaryRequest(String request) {
    for (final run in _active) {
      if (run.requestId == request && run.active) {
        run.cancel();
        return true;
      }
    }
    return false;
  }

  Future<void> generateSummary(
    int id, {
    String? requestId,
    bool Function()? current,
    bool refresh = true,
  }) async {
    if (_closed) throw RpcError(RpcErrorCode.unavailable, 'Application closed');
    await generation.yieldToForeground();
    if (generation.busy) {
      throw RpcError(RpcErrorCode.busy, 'Generation already in progress');
    }
    final revision = meetings.revision(id);
    if (revision == null) {
      throw RpcError(RpcErrorCode.notFound, 'Meeting not found: $id');
    }
    final workspace = domain.workspaceGeneration;
    final runtime = domain.generator;
    if (runtime == null) throw StateError('Generation model unavailable');
    final digest = modelDigest();
    final effective = Map<String, dynamic>.of(runtime.effectiveState);
    final context = effective['context_length'] as int? ?? 4096;
    final outputTokens = (context ~/ 4).clamp(128, 1024);
    final identity = summaryDigest(
      jsonEncode({
        'version': summaryVersion,
        'policy': summaryPolicyVersion,
        'model': digest,
        'model_registration': store.sourceQueries.model('generation')?.toRow(),
        'context': context,
        'output_tokens': outputTokens,
        'token_budget': 'utf8-byte-bound-v1',
        'backend': effective['backend'],
      }),
    );
    final transcript = cleanSummaryTranscript(
      meetings
          .finalTranscriptText(id)
          .map((text) => extractSavedTranscriptText(text).trim())
          .where((text) => text.isNotEmpty)
          .join('\n\n'),
    );
    if (transcript.isEmpty) throw StateError('No final transcript');
    final checkpointRow = store.summaryCheckpoint(id);
    final checkpoint = checkpointRow == null
        ? null
        : SummaryCheckpoint(
            body: checkpointRow['generated'] as String,
            inputLength: checkpointRow['input_length'] as int,
            inputDigest: checkpointRow['input_digest'] as String,
            identity: checkpointRow['identity'] as String,
          );
    final run = _SummaryRun(
      requestId ?? 'summary-${domain.clock.now().microsecondsSinceEpoch}',
      runtime,
    );
    final reservation = generation.reserve(run.requestId, cancel: run.cancel);
    _summaries[id] = run;
    _active.add(run);
    void check() {
      domain.checkWorkspace(workspace);
      if (_closed ||
          run.cancelled ||
          !(current?.call() ?? true) ||
          !identical(_summaries[id], run) ||
          !identical(domain.generator, runtime)) {
        throw RpcError(RpcErrorCode.cancelled, 'Summary cancelled');
      }
      final latest = meetings.revision(id);
      if (latest != revision || modelDigest() != digest) {
        throw RpcError(
          RpcErrorCode.cancelled,
          'Meeting or model changed; regenerate the summary',
        );
      }
    }

    var child = 0;
    changed();
    try {
      check();
      final producer = SummaryGenerator(
        contextTokens: context,
        outputTokens: outputTokens,
        checkCurrent: check,
        countTokens: (text) async {
          check();
          // Encode uses the embedding model's tokenizer, whose counts do not
          // bound generation models. Until a generation-bound tokenizer exists,
          // use the conservative byte bound regardless of helper readiness.
          return utf8.encode(text).length;
        },
        onProgress: (progress) {
          check();
          run.progress = progress;
          changed();
        },
        complete: (prompt, system, preview) => _completeChild(
          run,
          '${run.requestId}-summary-${++child}',
          prompt,
          system,
          preview,
          outputTokens,
          check,
        ),
      );
      final result = await producer.generate(
        transcript,
        identity: identity,
        checkpoint: checkpoint,
        refresh: refresh,
      );
      check();
      _accept(
        id,
        result,
        requestId: run.requestId,
        digest: digest,
        revision: revision,
        transcript: transcript,
        identity: identity,
        effective: effective,
        outputTokens: outputTokens,
      );
      run.progress = const SummaryProgress('completed');
    } catch (error) {
      run.error = error.toString();
      run.progress = const SummaryProgress('failed');
      rethrow;
    } finally {
      run.active = false;
      reservation.settle();
      _active.remove(run);
      if (!run.finished.isCompleted) run.finished.complete();
      changed();
    }
  }

  void _accept(
    int id,
    SummaryResult result, {
    required String requestId,
    required String digest,
    required int revision,
    required String transcript,
    required String identity,
    required Map<String, dynamic> effective,
    required int outputTokens,
  }) {
    if (result.mode != 'cached') {
      // No await between the final snapshot check and the atomic commit.
      final source = store.saveSummary(
        id,
        result.body,
        digest,
        revision: revision,
        inputLength: transcript.length,
        inputDigest: summaryDigest(transcript),
        identity: identity,
        manifest: {
          'version': summaryVersion,
          'policy': summaryPolicyVersion,
          'request_id': requestId,
          'identity': identity,
          'input_revision': revision,
          'input_digest': summaryDigest(transcript),
          'model_digest': digest,
          'effective_settings': effective,
          'output_tokens': outputTokens,
          'tokenizer': 'utf8-byte-bound-v1',
          'mode': result.mode,
          'chunks': result.chunks,
          'reduction_clipped': result.joinClipped,
          'outcome': 'completed',
        },
      );
      // Derived indexing is a resumable source job; it cannot delay or
      // relabel the already committed summary. The transcript remains separate.
      unawaited(
        domain.index(source).catchError((Object error) {
          stderr.writeln('Summary indexing: $error');
        }),
      );
    }
  }

  Future<String> _completeChild(
    _SummaryRun run,
    String childId,
    String prompt,
    String system,
    void Function(String) preview,
    int outputTokens,
    void Function() check,
  ) async {
    check();
    run.child = childId;
    var body = '', status = 'failed', failure = '';
    final monitor = Timer.periodic(const Duration(milliseconds: 20), (_) {
      try {
        check();
      } catch (_) {
        run.cancel();
      }
    });
    try {
      await for (final event in run.runtime.generateSummary(
        childId,
        prompt,
        systemPrompt: system,
        maxOutputTokens: outputTokens,
      )) {
        check();
        switch (event['type']) {
          case 'delta':
            body += event['text'] as String;
            preview(body);
          case 'preview':
            preview(event['text'] as String);
          case 'error':
            failure = event['message'].toString();
          case 'done':
            status = event['status'] as String;
        }
      }
      check();
      if (status != 'completed') {
        throw StateError('Summary generation $status: $failure');
      }
      return body;
    } finally {
      monitor.cancel();
      run.runtime.cancel(requestId: childId);
      run.child = null;
    }
  }
}
