part of 'application.dart';

class _SummaryRun {
  _SummaryRun(this.requestId, this.runtime);
  final String requestId;
  final NativeRuntime runtime;
  String? child;
  bool active = true, cancelled = false;
  String error = '';
  SummaryProgress progress = const SummaryProgress('planning');
  Map<String, Object?> get state => {
    ...progress.json,
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

extension ApplicationSummary on Application {
  /// Cancellation belongs to the public request, including whichever native
  /// child is currently executing. A disconnected lease cannot cancel a peer.
  bool cancelSummaryRequest(String request) {
    for (final run in _summaries.values) {
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
    if (proactive.running) await proactive.yieldToForeground();
    if (_noteEnhancements.values.any((run) => run.active && run.isLive)) {
      await _yieldLiveEnhancements();
    }
    if (_closed) throw RpcError(RpcErrorCode.unavailable, 'Application closed');
    if (modelBusy ||
        _workflowBusy ||
        _summarizing ||
        _activeEnhancements > 0 ||
        domain.generator?.generating == true) {
      throw RpcError(RpcErrorCode.busy, 'Generation already in progress');
    }
    final meeting = _meeting(id);
    final revision = meeting['revision'] as int;
    final workspace = domain.workspaceGeneration;
    final runtime = domain.generator;
    if (runtime == null) throw StateError('Generation model unavailable');
    final digest = _digest;
    final effective = Map<String, dynamic>.of(runtime.effectiveState);
    final context = effective['context_length'] as int? ?? 4096;
    final outputTokens = (context ~/ 4).clamp(128, 1024);
    final identity = summaryDigest(
      jsonEncode({
        'version': summaryVersion,
        'policy': summaryPolicyVersion,
        'model': digest,
        'model_registration': store.model('generation'),
        'context': context,
        'output_tokens': outputTokens,
        'token_budget': 'utf8-byte-bound-v1',
        'backend': effective['backend'],
      }),
    );
    final transcript = cleanSummaryTranscript(_noteTranscriptText(id));
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
    _summaries[id] = run;
    void check() {
      domain.checkWorkspace(workspace);
      if (_closed ||
          run.cancelled ||
          !(current?.call() ?? true) ||
          !identical(_summaries[id], run) ||
          !identical(domain.generator, runtime)) {
        throw RpcError(RpcErrorCode.cancelled, 'Summary cancelled');
      }
      final latest = store.rows('SELECT revision FROM meetings WHERE id=?', [
        id,
      ]).firstOrNull;
      if (latest == null ||
          latest['revision'] != revision ||
          _digest != digest) {
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
        complete: (prompt, system, preview) async {
          check();
          final childId = '${run.requestId}-summary-${++child}';
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
            await for (final event in runtime.generateSummary(
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
            runtime.cancel(requestId: childId);
            run.child = null;
          }
        },
      );
      final result = await producer.generate(
        transcript,
        identity: identity,
        checkpoint: checkpoint,
        refresh: refresh,
      );
      check();
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
            'request_id': run.requestId,
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
      run.progress = SummaryProgress('completed', preview: result.body);
    } catch (error) {
      run.error = error.toString();
      run.progress = const SummaryProgress('failed');
      rethrow;
    } finally {
      run.active = false;
      changed();
    }
  }
}
