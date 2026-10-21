part of 'application.dart';

class _MeetingWorkflowRun {
  _MeetingWorkflowRun(this.parent, this.runtime);
  final String parent;
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

class _MeetingWorkflowContext {
  _MeetingWorkflowContext(
    this.check,
    this.complete,
    this.progress,
    this.identity,
    this.model,
    this.revision,
    this.context,
    this.output,
  );
  final void Function() check;
  final SummaryComplete complete;
  final void Function(SummaryProgress) progress;
  final String identity, model;
  final int revision, context, output;
}

extension ApplicationMeetingWorkflows on Application {
  bool cancelMeetingWorkflowRequest(String parent) {
    var owned = false;
    for (final run in _workflows.values) {
      if (run.active && run.parent == parent) {
        run.cancel();
        owned = true;
      }
    }
    for (final run in _noteEnhancements.values) {
      if (run.active && run.requestId == parent) {
        run.cancelRequested = true;
        if (run.child case final id?) run.runtime?.cancel(requestId: id);
        owned = true;
      }
    }
    return owned;
  }

  Future<T> _meetingWorkflow<T>(
    int meeting,
    String kind, {
    String? requestId,
    bool Function()? current,
    void Function()? checkInputs,
    required Future<T> Function(_MeetingWorkflowContext) execute,
  }) async {
    if (_closed) throw RpcError(RpcErrorCode.unavailable, 'Application closed');
    // Foreground requests preempt automatic answer work, which retains its
    // durable queued job. The native owner must finish cancellation first.
    if (proactive.running) {
      await proactive.yieldToForeground();
    }
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
    final row = _meeting(meeting), workspace = domain.workspaceGeneration;
    final runtime = domain.generator;
    if (runtime == null) {
      throw RpcError(RpcErrorCode.unavailable, 'Generation model unavailable');
    }
    final model = _digest;
    final notesRevision = store.rows(
      'SELECT revision FROM meeting_notes WHERE meeting_id=?',
      [meeting],
    ).firstOrNull?['revision'];
    final key = '$meeting:$kind';
    final run = _MeetingWorkflowRun(
      requestId ?? '$kind-${domain.clock.now().microsecondsSinceEpoch}',
      runtime,
    );
    _workflows[key] = run;
    void check() {
      domain.checkWorkspace(workspace);
      if (_closed ||
          run.cancelled ||
          !(current?.call() ?? true) ||
          !identical(_workflows[key], run) ||
          !identical(domain.generator, runtime)) {
        throw RpcError(RpcErrorCode.cancelled, 'Meeting generation cancelled');
      }
      if (_meeting(meeting)['revision'] != row['revision'] ||
          _digest != model ||
          store.rows('SELECT revision FROM meeting_notes WHERE meeting_id=?', [
                meeting,
              ]).firstOrNull?['revision'] !=
              notesRevision) {
        throw RpcError(
          RpcErrorCode.cancelled,
          'Meeting inputs changed; regenerate',
        );
      }
      checkInputs?.call();
    }

    var child = 0;
    final context = runtime.effectiveState['context_length'] as int? ?? 4096;
    final output = (context ~/ 4).clamp(128, 768);
    void progress(SummaryProgress progress) {
      check();
      run.progress = progress;
      changed();
    }

    Future<String> complete(
      String prompt,
      String system,
      void Function(String) preview,
    ) async {
      check();
      if (utf8.encode('$system\n\n$prompt').length + output + 128 > context) {
        throw StateError('Meeting request exceeds model context');
      }
      final id = '${run.parent}-$kind-${++child}';
      run.child = id;
      var result = '', status = 'failed', failure = '';
      final monitor = Timer.periodic(const Duration(milliseconds: 20), (_) {
        try {
          check();
        } catch (_) {
          run.cancel();
        }
      });
      try {
        await for (final event in runtime.generateSummary(
          id,
          prompt,
          systemPrompt: system,
          maxOutputTokens: output,
        )) {
          check();
          if (event['type'] == 'delta') {
            result += event['text'] as String;
            preview(result);
          }
          if (event['type'] == 'preview') preview(event['text'] as String);
          if (event['type'] == 'error') failure = event['message'].toString();
          if (event['type'] == 'done') status = event['status'] as String;
        }
        check();
        if (status != 'completed' || result.trim().isEmpty) {
          throw StateError('Meeting generation $status: $failure');
        }
        return result.trim();
      } finally {
        monitor.cancel();
        runtime.cancel(requestId: id);
        run.child = null;
      }
    }

    final identity = summaryDigest(
      jsonEncode([
        kind,
        kind == 'actions' ? meetingActionsVersion : preparationVersion,
        workflowSourcePolicy,
        if (kind == 'actions')
          meetingActionsInstructions
        else ...[
          documentSummaryInstructions,
          documentMapPrefix,
          documentReducePrefix,
          preparationSynthesisInstructions,
        ],
        store.model('generation'),
        runtime.effectiveState,
        context,
        output,
        'utf8-byte-bound-v1',
      ]),
    );
    changed();
    try {
      check();
      final result = await execute(
        _MeetingWorkflowContext(
          check,
          complete,
          progress,
          identity,
          model,
          row['revision'] as int,
          context,
          output,
        ),
      );
      run.progress = const SummaryProgress('completed');
      return result;
    } catch (error) {
      run.error = error.toString();
      run.progress = const SummaryProgress('failed');
      rethrow;
    } finally {
      run.active = false;
      changed();
      proactive.wake();
    }
  }

  Future<void> generateActions(
    int id, {
    String? requestId,
    bool Function()? current,
  }) => _meetingWorkflow<void>(
    id,
    'actions',
    requestId: requestId,
    current: current,
    execute: (run) async {
      final evidence = [
        for (final row in store.rows(
          'SELECT id,text FROM transcript WHERE meeting_id=? AND final=1 ORDER BY id',
          [id],
        ))
          MeetingEvidence(
            'transcript:${row['id']}',
            extractSavedTranscriptText(row['text'] as String),
          ),
        if (store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
              id,
            ]).firstOrNull?['body']
            case final String text)
          MeetingEvidence('notes:$id', text),
      ];
      final tasks = await extractMeetingActions(
        evidence: evidence,
        complete: run.complete,
        checkCurrent: run.check,
        onProgress: run.progress,
        context: run.context,
        output: run.output,
      );
      run.check();
      final source = store
          .saveMeetingTasks(id, tasks, run.model, run.revision, {
            'version': meetingActionsVersion,
            'identity': run.identity,
            'input_revision': run.revision,
            'input_digest': summaryDigest(
              jsonEncode(evidence.map((entry) => entry.json).toList()),
            ),
            'outcome': 'completed',
            'tasks': tasks.length,
          });
      _indexWorkflowSource(source);
    },
  );

  void _indexWorkflowSource(String source) {
    unawaited(
      domain.index(source).catchError((Object error) {
        stderr.writeln('Meeting artifact indexing: $error');
      }),
    );
  }
}
