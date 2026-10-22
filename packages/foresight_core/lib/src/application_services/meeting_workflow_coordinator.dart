import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain.dart';
import '../read_models.dart';
import '../meeting_actions.dart';
import '../meeting_preparation.dart';
import '../meeting_workflow_store.dart';
import '../native.dart';
import '../persistence/source_admission_queries.dart';
import '../persistence/workflow_queries.dart';
import '../rpc_error.dart';
import '../store.dart';
import '../summary_generator.dart';
import 'generation_coordinator.dart';

class _MeetingWorkflowRun {
  _MeetingWorkflowRun(this.parent, this.runtime);
  final String parent;
  final NativeRuntime runtime;
  String? child;
  final finished = Completer<void>();
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

/// Actions and document Preparation retain one owner for native children,
/// accepted tasks/artifacts/cache writes, and their progress presentation.
final class MeetingWorkflowCoordinator {
  MeetingWorkflowCoordinator({
    required this.domain,
    required this.generation,
    required this.modelDigest,
    required this.changed,
    required this.wakeAutomatic,
  }) : queries = WorkflowQueries(domain.store),
       sources = SourceAdmissionQueries(domain.store);
  final Domain domain;
  final GenerationCoordinator generation;
  final String Function() modelDigest;
  final void Function() changed, wakeAutomatic;
  final WorkflowQueries queries;
  final SourceAdmissionQueries sources;
  Store get store => domain.store;
  final _workflows = <String, _MeetingWorkflowRun>{};
  final _active = <_MeetingWorkflowRun>{};
  bool _closed = false;
  Future<void>? _closing;
  bool get busy => _active.isNotEmpty;
  Map<String, Object?> get state => {
    for (final entry in _workflows.entries) entry.key: entry.value.state,
  };
  void cancelMeeting(int id, String? kind) => _workflows['$id:$kind']?.cancel();
  void clear() {
    for (final run in _active) {
      run.cancel();
    }
    _workflows.clear();
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

  bool cancelMeetingWorkflowRequest(String parent) {
    var owned = false;
    for (final run in _active) {
      if (run.active && run.parent == parent) {
        run.cancel();
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
    await generation.yieldToForeground();
    if (generation.busy) {
      throw RpcError(RpcErrorCode.busy, 'Generation already in progress');
    }
    final row = queries.meeting(meeting),
        workspace = domain.workspaceGeneration;
    final runtime = domain.generator;
    if (runtime == null) {
      throw RpcError(RpcErrorCode.unavailable, 'Generation model unavailable');
    }
    final model = modelDigest();
    final notesRevision = queries.notesRevision(meeting);
    final key = '$meeting:$kind';
    final run = _MeetingWorkflowRun(
      requestId ?? '$kind-${domain.clock.now().microsecondsSinceEpoch}',
      runtime,
    );
    final reservation = generation.reserve(run.parent, cancel: run.cancel);
    _workflows[key] = run;
    _active.add(run);
    void check() {
      domain.checkWorkspace(workspace);
      if (_closed ||
          run.cancelled ||
          !(current?.call() ?? true) ||
          !identical(_workflows[key], run) ||
          !identical(domain.generator, runtime)) {
        throw RpcError(RpcErrorCode.cancelled, 'Meeting generation cancelled');
      }
      if (queries.meeting(meeting).revision != row.revision ||
          modelDigest() != model ||
          queries.notesRevision(meeting) != notesRevision) {
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
    ) => _completeChild(
      run,
      '${run.parent}-$kind-${++child}',
      prompt,
      system,
      preview,
      output,
      context,
      check,
    );

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
        store.sourceQueries.model('generation')?.toRow(),
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
          row.revision,
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
      reservation.settle();
      changed();
      _active.remove(run);
      if (!run.finished.isCompleted) run.finished.complete();
      wakeAutomatic();
    }
  }

  Future<String> _completeChild(
    _MeetingWorkflowRun run,
    String id,
    String prompt,
    String system,
    void Function(String) preview,
    int output,
    int context,
    void Function() check,
  ) async {
    check();
    if (utf8.encode('$system\n\n$prompt').length + output + 128 > context) {
      throw StateError('Meeting request exceeds model context');
    }
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
      await for (final event in run.runtime.generateSummary(
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
      run.runtime.cancel(requestId: id);
      run.child = null;
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
      final evidence = queries.actionEvidence(id);
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
      indexSource(source);
    },
  );

  void indexSource(String source) {
    unawaited(
      domain.index(source).catchError((Object error) {
        stderr.writeln('Meeting artifact indexing: $error');
      }),
    );
  }

  Future<void> prepareMeeting(
    int id,
    List<String> sourceIds, {
    String? requestId,
    bool Function()? current,
  }) async {
    if (sourceIds.isEmpty ||
        sourceIds.length > 100 ||
        sourceIds.toSet().length != sourceIds.length) {
      throw ArgumentError('Select between one and 100 distinct documents');
    }
    final sources = <SourceDocument>[];
    for (final sourceId in sourceIds) {
      final source = this.sources.active(sourceId);
      if (source == null) {
        throw RpcError(
          RpcErrorCode.notFound,
          'Selected document no longer exists',
        );
      }
      if (sourceId.startsWith('meeting-preparation-')) {
        throw ArgumentError('A preparation brief cannot be its own source');
      }
      sources.add(source);
    }
    final meeting = queries.meeting(id);
    final event = queries.calendarMetadata(id);
    void checkSources() {
      for (final source in sources) {
        if (!this.sources.isCurrent(source.id, source.revision)) {
          throw RpcError(
            RpcErrorCode.cancelled,
            'Preparation document changed; regenerate',
          );
        }
      }
      if (queries.meeting(id).title != meeting.title ||
          queries.calendarMetadata(id) != event) {
        throw RpcError(
          RpcErrorCode.cancelled,
          'Meeting event changed; regenerate',
        );
      }
    }

    await _meetingWorkflow<void>(
      id,
      'preparation',
      requestId: requestId,
      current: current,
      checkInputs: checkSources,
      execute: (run) async {
        final fingerprint = summaryDigest(
          jsonEncode([
            run.identity,
            meeting.title,
            event,
            (sources
                .map(
                  (source) =>
                      '${source.id}:${source.revision}:${summaryDigest(source.content)}',
                )
                .toList()
              ..sort()),
          ]),
        );
        final latest = store.meetingQueries
            .artifacts(id, 'preparation')
            .firstOrNull;
        if (latest != null && latest.edited == null) {
          final saved = latest.manifest;
          if (saved['fingerprint'] == fingerprint &&
              saved['degraded'] != true) {
            return;
          }
        }
        final documents = await _summarizeDocuments(sources, run);
        final summaries = documents.summaries,
            errors = documents.errors,
            cache = documents.cache;
        var clipped = documents.clipped;
        if (summaries.isEmpty) {
          throw StateError(
            'No document summaries available${errors.isEmpty ? '' : ': ${errors.map((error) => error['error']).join('; ')}'}',
          );
        }
        var body = summaries.singleOrNull ?? '';
        if (summaries.length > 1) {
          final prefix =
              '$preparationSynthesisInstructions\n\nMeeting context: ${jsonEncode({'title': meeting.title, 'event': event})}\n\n';
          final joined = fitWorkflowPartials(
            summaries,
            system: documentSummaryInstructions,
            prefix: prefix,
            context: run.context,
            output: run.output,
          );
          clipped |= joined.clipped;
          run.progress(const SummaryProgress('synthesizing'));
          body = await run.complete(
            '$prefix${joined.text}',
            documentSummaryInstructions,
            (text) =>
                run.progress(SummaryProgress('synthesizing', preview: text)),
          );
        }
        if (errors.isNotEmpty) {
          body +=
              '\n\n## Unavailable documents\n${errors.map((error) => '- ${error['title']}').join('\n')}';
        }
        run.check();
        final source = store.workflowTransaction(() {
          queries.cacheDocumentSummaries(cache);
          return store.saveWorkflowArtifact(
            id,
            'preparation',
            body,
            run.model,
            run.revision,
            {
              'version': preparationVersion,
              'identity': run.identity,
              'fingerprint': fingerprint,
              'sources': [
                for (final source in sources)
                  {'id': source.id, 'revision': source.revision},
              ],
              'errors': errors,
              'degraded': errors.isNotEmpty,
              'reduction_clipped': clipped,
            },
          );
        });
        indexSource(source);
      },
    );
  }

  Future<
    ({
      List<String> summaries,
      List<Map<String, String>> errors,
      List<List<Object?>> cache,
      bool clipped,
    })
  >
  _summarizeDocuments(
    List<SourceDocument> sources,
    _MeetingWorkflowContext run,
  ) async {
    final summaries = <String>[],
        errors = <Map<String, String>>[],
        cache = <List<Object?>>[];
    var clipped = false;
    for (var i = 0; i < sources.length; i++) {
      run.check();
      final source = sources[i];
      final key = summaryDigest(
        jsonEncode([
          preparationVersion,
          run.identity,
          source.id,
          source.revision,
          source.title,
          summaryDigest(source.content),
        ]),
      );
      try {
        final cached = queries.documentSummary(key);
        if (cached?.clipped == true) clipped = true;
        var body = cached?.body;
        if (body == null) {
          final result = await summarizePreparationDocument(
            source.content,
            complete: run.complete,
            checkCurrent: run.check,
            onProgress: run.progress,
            context: run.context,
            output: run.output,
          );
          body = result.body;
          clipped |= result.clipped;
          cache.add([
            key,
            source.id,
            source.revision,
            body,
            run.identity,
            result.clipped ? 1 : 0,
          ]);
        }
        if (body.isNotEmpty) {
          summaries.add('Document ${i + 1}: ${source.title}\n$body');
        }
      } catch (error) {
        run.check(); // Cancellation/stale input cannot become partial success.
        errors.add({
          'id': source.id,
          'title': source.title,
          'error': error.toString(),
        });
      }
      run.progress(
        SummaryProgress('documents', completed: i + 1, total: sources.length),
      );
    }
    return (
      summaries: List<String>.unmodifiable(summaries),
      errors: List<Map<String, String>>.unmodifiable(errors),
      cache: List<List<Object?>>.unmodifiable(cache),
      clipped: clipped,
    );
  }
}
