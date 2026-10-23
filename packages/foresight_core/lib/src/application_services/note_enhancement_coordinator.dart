import 'dart:async';
import 'dart:io';

import 'package:grpc/grpc.dart';

import '../domain.dart';
import '../read_models.dart';
import '../generated/rag_service.pb.dart';
import '../meeting_speakers.dart';
import '../meeting_workflow_store.dart';
import '../native.dart';
import '../native_note_enhancement.dart';
import '../persistence/meeting_queries.dart';
import '../persistence/note_queries.dart';
import '../proactive_questions.dart';
import '../reference_note_edit_mapping.dart';
import '../reference_note_enhancement.dart';
import '../reference_note_enhancement_chunking.dart';
import '../reference_note_enhancer.dart';
import '../reference_note_live_plan.dart';
import '../reference_note_service_recovery.dart';
import '../reference_note_transcript_cache.dart';
import '../reference_note_transcript_format.dart';
import '../rpc_error.dart';
import '../store.dart';
import 'capture_activity.dart';
import 'generation_coordinator.dart';

/// Owns Notes edits, live/final grounding, timers, drafts and native children.
/// No capture process or parent Application is retained here.
final class NoteEnhancementCoordinator {
  NoteEnhancementCoordinator({
    required this.domain,
    required this.generation,
    required this.proactive,
    required this.meetings,
    required this.capture,
    required this.changed,
    required this.indexSource,
    required this.modelDigest,
  }) : queries = NoteQueries(domain.store, meetings);
  final Domain domain;
  final GenerationCoordinator generation;
  final ProactiveQuestions proactive;
  final MeetingQueries meetings;
  final CaptureActivity capture;
  final void Function() changed;
  final void Function(String) indexSource;
  final String Function() modelDigest;
  final NoteQueries queries;
  Store get store => domain.store;
  bool get modelBusy => generation.modelBusy;
  bool get generationReserved => generation.generationReserved;
  final _enhance = <int, Timer>{};
  final _noteEnhancements = <int, _NoteEnhancement>{};
  final _noteEditMappings = <int, ReferenceNoteEditMapping>{};
  final _pendingNoteTargets = <int, Set<int>>{};
  final _running = <_NoteEnhancement>{};
  int _activeEnhancements = 0;
  bool _closed = false;
  Future<void>? _closing;
  Completer<void>? _cacheIdle;
  int get activeWork => _activeEnhancements;
  int get computing => _noteTranscriptCache.computing;
  bool get hasLiveWork => _running.any((run) => run.active && run.isLive);
  Map<String, Object?> get state => {
    for (final entry in _noteEnhancements.entries)
      '${entry.key}': entry.value.state,
  };

  void _cacheSettled() {
    if (computing == 0 && _cacheIdle?.isCompleted == false) {
      _cacheIdle!.complete();
    }
    changed();
  }

  void invalidateEmbeddings() => _noteTranscriptCache.clear();
  void invalidateTranscript(int id) => _noteTranscriptCache.invalidate(id);

  void clear() {
    for (final timer in _enhance.values) {
      timer.cancel();
    }
    _enhance.clear();
    for (final state in _running) {
      state.cancelRequested = true;
      state.saveTimer?.cancel();
      if (state.child case final child?) {
        state.runtime?.cancel(requestId: child);
      }
    }
    for (final state in _noteEnhancements.values) {
      state.saveTimer?.cancel();
    }
    _noteEnhancements.clear();
    _noteEditMappings.clear();
    _pendingNoteTargets.clear();
    _noteTranscriptCache.clear();
  }

  void stop() {
    if (_closed) return;
    _closed = true;
    for (final timer in _enhance.values) {
      timer.cancel();
    }
    _enhance.clear();
    for (final entry in _noteEnhancements.entries) {
      final enhancement = entry.value;
      enhancement.saveTimer?.cancel();
      enhancement.cancelRequested = true;
      if (enhancement.child case final child?) {
        enhancement.runtime?.cancel(requestId: child);
      }
      final previous = enhancement.restoreBody;
      if (enhancement.active && previous != null) {
        store.restoreMeetingEnhancedDraft(entry.key, previous);
        _restoreNoteMapping(entry.key, queries.body(entry.key), previous);
      }
    }
    _noteEnhancements.clear();
    _noteTranscriptCache.clear();
  }

  Future<void> close() => _closing ??= Future.sync(() async {
    stop();
    await Future.wait(_running.map((run) => run.finished.future));
    if (computing > 0) await (_cacheIdle ??= Completer<void>()).future;
  });

  bool cancelRequest(String parent) {
    var owned = false;
    for (final run in _running) {
      if (run.active && run.requestId == parent) {
        run.cancelRequested = true;
        if (run.child case final child?) run.runtime?.cancel(requestId: child);
        owned = true;
      }
    }
    return owned;
  }

  bool cancel(int id, String? requestId) {
    final run = _noteEnhancements[id];
    if (run == null || !run.active || run.requestId != requestId) return false;
    run.cancelRequested = true;
    if (run.child case final child?) run.runtime?.cancel(requestId: child);
    changed();
    return true;
  }

  void saveNotes(int id, String body, {int? lastManualEdit}) {
    queries.meetingRevision(id);
    final oldNotes = queries.note(id)?.body;
    final previous = _currentEnhancedNotes(id);
    _noteEditMapping(id);
    store.saveMeetingNotes(id, body, lastManualEdit: lastManualEdit);
    if (oldNotes != body) {
      _shorthandEdited(id, body, previous);
      _scheduleNoteEditEnhancement(id, oldNotes ?? '', body);
    }
  }

  NoteArtifactEdit? beforeArtifactEdit(int id) {
    final before = queries.selectedArtifact(id);
    if (before != null) _noteEditMapping(before.meeting);
    return before;
  }

  void afterArtifactEdit(int id, String text, NoteArtifactEdit? before) {
    final selected = queries.selectedArtifact(id);
    if (selected == null) return;
    final meeting = selected.meeting;
    final enhancement = _noteEnhancements[meeting];
    if (enhancement?.active != true &&
        (before?.edited ?? before?.generated) != text) {
      _noteEditMapping(
        meeting,
      ).updateStaleBullets(notes: queries.body(meeting), enhancedNotes: text);
    }
    if (enhancement == null) return;
    if (enhancement.active) {
      enhancement.cancelRequested = true;
      enhancement.restoreBody = text;
      if (enhancement.child case final child?) {
        enhancement.runtime?.cancel(requestId: child);
      }
    }
    enhancement.saveTimer?.cancel();
    enhancement.body = text;
    if (!enhancement.active) _noteEnhancements.remove(meeting);
  }

  late final ReferenceNoteTranscriptCache _noteTranscriptCache =
      ReferenceNoteTranscriptCache(
        computeEmbedding: _computeNoteEmbedding,
        currentIsLive: (id) => capture.meeting == id && capture.active,
        loadSavedTranscript: (id) async => _noteTranscriptText(id),
        onSettled: _cacheSettled,
      );

  Future<List<double>> _computeNoteEmbedding(String text) async {
    if (_closed || domain.helper.snapshot?.pipeline != 'ready') return [];
    final response = await domain.helper.client.computeEmbedding(
      ComputeEmbeddingRequest(text: text),
      options: CallOptions(timeout: const Duration(seconds: 5)),
    );
    return response.embedding.toList();
  }

  String _noteTranscriptText(int id) => meetings
      .finalTranscriptText(id)
      .map((text) => extractSavedTranscriptText(text).trim())
      .where((text) => text.isNotEmpty)
      .join('\n\n');

  Iterable<({String speaker, String text})> _liveNoteTranscriptSegments(
    int id,
  ) => meetings.transcript(id, finalOnly: true).map((row) {
    final speaker = MeetingSpeaker.fromSource(row.source);
    return (
      speaker: speaker == MeetingSpeaker.unknown ? '' : speaker.label,
      text: row.text,
    );
  });

  void scheduleLiveTranscript(int id) {
    if (_closed || capture.meeting != id || !capture.active) return;
    final text = formatLiveNoteTranscript(_liveNoteTranscriptSegments(id));
    if (text.isEmpty) return;
    unawaited(
      _noteTranscriptCache.schedule(id, text, isLive: true).catchError((
        Object e,
      ) {
        stderr.writeln('Live transcript embedding: $e');
      }),
    );
  }

  Future<List<EmbeddedNoteTranscriptChunk>> _embeddedNoteTranscript(
    int id,
    String transcript, {
    required bool isLive,
    void Function()? checkCurrent,
  }) async {
    // Final enhancement covers the complete saved transcript. The live cache
    // retains its reference latest-50 behavior and is reused by exact text.
    if (!isLive) {
      final cached = await _noteTranscriptCache.getEmbeddedChunks(id);
      final vectors = {for (final chunk in cached) chunk.text: chunk.embedding};
      final complete = <EmbeddedNoteTranscriptChunk>[];
      for (final text in chunkNoteEnhancementTranscript(
        transcript,
        maxChunks: null,
      )) {
        checkCurrent?.call();
        if (_closed) throw RpcError(RpcErrorCode.cancelled, 'Notes closed');
        complete.add((
          text: text,
          embedding: vectors[text] ?? await _computeNoteEmbedding(text),
        ));
      }
      return complete;
    }
    if (isLive && capture.meeting == id && capture.active) {
      final text = formatLiveNoteTranscript(_liveNoteTranscriptSegments(id));
      if (text.isNotEmpty) {
        await _noteTranscriptCache.schedule(id, text, isLive: true);
      }
    }
    final cached = await _noteTranscriptCache.getEmbeddedChunks(id);
    if (cached.isNotEmpty) return cached;
    final chunks = <EmbeddedNoteTranscriptChunk>[];
    for (final text in chunkNoteEnhancementTranscript(
      transcript,
      isLive: isLive,
    )) {
      chunks.add((text: text, embedding: await _computeNoteEmbedding(text)));
    }
    return chunks;
  }

  String _currentEnhancedNotes(int id) {
    final pending = _noteEnhancements[id];
    return pending != null && !pending.active && pending.status.isEmpty
        ? pending.body
        : store.meetingEnhancedNotes(id);
  }

  ReferenceNoteEditMapping _noteEditMapping(int id) =>
      _noteEditMappings.putIfAbsent(
        id,
        () => ReferenceNoteEditMapping.fromNotes(
          notes: queries.body(id),
          enhancedNotes: _currentEnhancedNotes(id),
        ),
      );

  void _restoreNoteMapping(int id, String notes, String enhancedNotes) {
    final mapping = _noteEditMapping(id);
    final restored = ReferenceNoteEditMapping.fromNotes(
      notes: notes,
      enhancedNotes: enhancedNotes,
    );
    mapping.accepted
      ..clear()
      ..addAll(restored.accepted);
    mapping.pairs
      ..clear()
      ..addAll(restored.pairs);
  }

  void _shorthandEdited(int id, String notes, String previousEnhanced) {
    if (_noteEnhancements[id]?.active == true) return;
    final mapping = _noteEditMapping(id);
    final replacement = mapping.syncShorthand(
      notes: notes,
      enhancedNotes: previousEnhanced,
    );
    if (replacement != null) {
      _noteEnhancements[id]?.saveTimer?.cancel();
      final draft = _NoteEnhancement(
        'note-edit-${++_noteEnhancementSerial}',
        replacement,
      )..active = false;
      _noteEnhancements[id] = draft;
      _scheduleEnhancedDraft(id, draft);
    }
    mapping.updateStaleBullets(
      notes: notes,
      enhancedNotes: replacement ?? previousEnhanced,
    );
  }

  int _noteEnhancementSerial = 0;
  void _requestAutomaticNoteEnhancement(int id, {Set<int>? targets}) {
    unawaited(
      enhanceNotes(
        id,
        deferWhenBusy: true,
        isLive: true,
        targetBulletIndices: targets,
      ).catchError((Object error) {
        capture.state = 'Note enhancement: $error';
        changed();
      }),
    );
  }

  void _scheduleNoteEditEnhancement(int id, String previous, String notes) {
    if (_closed || store.preference('liveEnhance', 'true') != 'true') return;
    final mapping = _noteEditMapping(id);
    final targets = planNoteLiveEnhancementTargets(
      previousNotes: previous,
      notes: notes,
      hasEnhanceableScribbles: hasEnhanceableNoteScribbles(notes),
      lastSuccessfulShorthand: mapping.lastSuccessfulShorthand,
      staleIndices: mapping.staleIndices,
    );
    if (targets == null) {
      scheduleEnhancement(id);
    } else if (targets.isNotEmpty) {
      _enhance.remove(id)?.cancel();
      _requestAutomaticNoteEnhancement(id, targets: targets);
    }
  }

  void scheduleEnhancement(int id) {
    if (_closed) return;
    _enhance.remove(id)?.cancel();
    if (store.preference('liveEnhance', 'true') != 'true') return;
    _enhance[id] = domain.createTimer(const Duration(seconds: 30), () {
      _enhance.remove(id);
      if (_noteEnhancements.values.any((state) => state.active)) return;
      _requestAutomaticNoteEnhancement(id);
    });
  }

  Future<void> yieldToForeground() async {
    final runs = _noteEnhancements.values
        .where((run) => run.active && run.isLive)
        .toList();
    for (final run in runs) {
      run.foregroundYielded = true;
      run.cancelRequested = true;
      if (run.child case final child?) run.runtime?.cancel(requestId: child);
    }
    await Future.wait(runs.map((run) => run.finished.future));
  }

  Future<void> enhanceNotes(
    int id, {
    bool deferWhenBusy = false,
    bool isLive = false,
    bool forceRegenerate = false,
    Set<int>? targetBulletIndices,
    String? requestId,
    bool Function()? current,
  }) async {
    if (current != null && !current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Generation cancelled');
    }
    if (!isLive) {
      if (proactive.running) await proactive.yieldToForeground();
      if (_noteEnhancements.values.any((run) => run.active && run.isLive)) {
        await yieldToForeground();
      }
    }
    if (_closed) throw RpcError(RpcErrorCode.unavailable, 'Application closed');
    if (generationReserved ||
        proactive.running ||
        domain.generator?.generating == true ||
        _noteEnhancements.values.any((state) => state.active)) {
      if (deferWhenBusy) {
        if (_noteEnhancements.values.any((state) => state.active)) {
          if (targetBulletIndices != null) {
            _pendingNoteTargets[id] = Set.of(targetBulletIndices);
          }
        } else {
          _scheduleEnhaseRetry(
            id,
            targetBulletIndices: targetBulletIndices,
            isLive: isLive,
          );
        }
        return;
      }
      throw RpcError(RpcErrorCode.busy, 'Generation already in progress');
    }
    final notes = queries.note(id);
    if (notes == null ||
        (notes.body).trim().isEmpty ||
        (isLive && !hasEnhanceableNoteScribbles(notes.body))) {
      return;
    }
    final transcript = isLive
        ? _liveNoteTranscriptSegments(id)
              .map(
                (segment) => formatNoteTranscriptSegment(
                  speaker: segment.speaker,
                  text: segment.text,
                ),
              )
              .join('\n')
        : _noteTranscriptText(id);
    if (transcript.isEmpty) return;
    final revision = queries.meetingRevision(id);
    final previousState = _noteEnhancements[id];
    previousState?.saveTimer?.cancel();
    final enhancement = _NoteEnhancement(
      requestId ??
          'notes-${domain.clock.now().microsecondsSinceEpoch}-${++_noteEnhancementSerial}',
      notes.body,
      current: current,
      isLive: isLive,
    );
    final previous =
        previousState != null &&
            !previousState.active &&
            (previousState.cancelRequested || previousState.status.isEmpty)
        ? previousState.body
        : store.meetingEnhancedNotes(id);
    enhancement.restoreBody = previous;
    await _runEnhancement(
      _NoteRun(
        id: id,
        notes: notes,
        transcript: transcript,
        revision: revision,
        enhancement: enhancement,
        previous: previous,
        mapping: _noteEditMapping(id),
        forceRegenerate: forceRegenerate,
        targetBulletIndices: targetBulletIndices,
      ),
    );
  }

  Future<void> _runEnhancement(_NoteRun run) async {
    final id = run.id, notes = run.notes, enhancement = run.enhancement;
    final mapping = run.mapping;
    final revision = run.revision;
    final current = enhancement.current, isLive = enhancement.isLive;
    final forceRegenerate = run.forceRegenerate;
    final targetBulletIndices = run.targetBulletIndices;
    bool noteCurrent() {
      if (_closed ||
          enhancement.cancelRequested ||
          !(current?.call() ?? true) ||
          !identical(_noteEnhancements[id], enhancement)) {
        return false;
      }
      final latest = queries.revision(id);
      if (latest != notes.revision ||
          (!isLive && queries.meetingRevision(id) != revision)) {
        enhancement.cancelRequested = true;
        return false;
      }
      return true;
    }

    void checkNote() {
      if (!noteCurrent()) {
        throw RpcError(
          RpcErrorCode.cancelled,
          'Notes changed or generation cancelled',
        );
      }
    }

    _noteEnhancements[id] = enhancement;
    _scheduleEnhancedDraft(id, enhancement);
    changed();
    GenerationReservation? reservation;
    _running.add(enhancement);
    _activeEnhancements++;
    try {
      if (modelBusy) {
        throw RpcError(RpcErrorCode.busy, 'Model configuration is busy');
      }
      reservation = generation.reserve(
        enhancement.requestId,
        cancel: () {
          enhancement.cancelRequested = true;
          if (enhancement.child case final child?) {
            enhancement.runtime?.cancel(requestId: child);
          }
        },
      );
      final prior = forceRegenerate
          ? null
          : Map<int, String>.of(mapping.accepted);
      if (forceRegenerate) mapping.accepted.clear();
      final producer = _producer(run, noteCurrent, checkNote);
      await for (final text in producer.enhance(
        notes: notes.body,
        existingEnhancedBullets: prior,
        targetBulletIndices: targetBulletIndices,
        isLive: isLive,
        updateExistingWithTranscript: !isLive && !forceRegenerate,
        concise: store.preference('noteStyle', 'Standard') == 'Concise',
        onActiveIndexChanged: (index) {
          enhancement.activeIndex = index;
          changed();
        },
      )) {
        if (_closed ||
            enhancement.cancelRequested ||
            !(current?.call() ?? true) ||
            !identical(_noteEnhancements[id], enhancement)) {
          throw RpcError(RpcErrorCode.cancelled, 'Generation cancelled');
        }
        if (isNoteEnhancementStatus(text)) {
          enhancement.status = text;
        } else {
          enhancement.body = cleanNoteEnhancementTags(text);
          enhancement.status = '';
          _scheduleEnhancedDraft(id, enhancement);
        }
        changed();
      }
      if (_closed ||
          enhancement.cancelRequested ||
          !(current?.call() ?? true) ||
          !identical(_noteEnhancements[id], enhancement)) {
        throw RpcError(RpcErrorCode.cancelled, 'Generation cancelled');
      }
      _accept(run, checkNote);
    } catch (error) {
      if (_restoreFailure(run, error)) return;
      rethrow;
    } finally {
      _settleRun(run, reservation);
    }
  }

  ReferenceNoteEnhancer _producer(
    _NoteRun run,
    bool Function() noteCurrent,
    void Function() checkNote,
  ) {
    final id = run.id, enhancement = run.enhancement;
    final transcript = run.transcript;
    final current = enhancement.current, isLive = enhancement.isLive;
    final failedBatches = run.failedBatches;
    late NativeRuntime generator;
    var batch = 0;
    return ReferenceNoteEnhancer(
      checkCurrent: checkNote,
      onBatchFailure: (indices, error) {
        failedBatches.add(indices);
      },
      ensureReady: () async {
        if (modelBusy) {
          throw RpcError(RpcErrorCode.busy, 'Model configuration is busy');
        }
        generator = await acquireNoteEnhancementService<NativeRuntime>(
          getService: domain.noteEnhancementService,
          isReady: (service) => service.loaded,
          abortAndReset: () async {
            stderr.writeln(
              'NotesEnhancer: LiteRT-LM service not ready, attempting reset and re-initialization...',
            );
            await domain.resetNoteEnhancementService();
          },
          unavailableError: () async => Exception(
            store.sourceQueries.model('generation') != null
                ? 'LiteRT-LM service is not ready. Please try again in a moment.'
                : 'LiteRT-LM service is not ready: on-device inference model is not downloaded. Please check Settings -> Model Management.',
          ),
        );
        if (generator.effectiveState['tools'] == false) {
          throw StateError(
            'Note enhancement requires a native conversation runtime',
          );
        }
        if (_closed ||
            enhancement.cancelRequested ||
            !(current?.call() ?? true) ||
            !identical(_noteEnhancements[id], enhancement)) {
          throw RpcError(RpcErrorCode.cancelled, 'Generation cancelled');
        }
      },
      loadEmbeddedTranscript: () => _embeddedNoteTranscript(
        id,
        transcript,
        isLive: isLive,
        checkCurrent: checkNote,
      ),
      computeEmbedding: domain.helper.snapshot?.pipeline == 'ready'
          ? _computeNoteEmbedding
          : null,
      // Embedding token IDs are not generation stop IDs. The producer's
      // textual stop markers remain active until generation-bound encoding
      // is available.
      encodeStopTokens: null,
      createConversation: (settings) async {
        checkNote();
        enhancement.runtime = generator;
        enhancement.child = '${enhancement.requestId}-batch-${++batch}';
        return NativeNoteEnhancementConversation.create(
          runtime: generator,
          requestId: enhancement.child!,
          settings: settings,
          current: noteCurrent,
        );
      },
      logBatchError: (error, stack) {
        stderr.writeln('Note enhancement batch: $error');
      },
    );
  }

  void _accept(_NoteRun run, void Function() checkNote) {
    final id = run.id, notes = run.notes, enhancement = run.enhancement;
    final mapping = run.mapping;
    final revision = run.revision;
    final isLive = enhancement.isLive;
    final failedBatches = run.failedBatches;
    enhancement.saveTimer?.cancel();
    checkNote();
    final source = store.workflowTransaction(() {
      store.artifact(
        id,
        'enhanced_notes',
        enhancement.body,
        modelDigest(),
        inputRevision: revision,
        manifest: {
          'version': 'notes-v2',
          'degraded': failedBatches.isNotEmpty,
          'failed_batches': failedBatches,
          'input_revision': revision,
          'notes_revision': notes.revision,
          'transcript_scope': isLive
              ? 'recent-50-chunks'
              : 'complete-candidate-history',
          'stop_policy': 'text-markers-v1',
        },
      );
      final accepted = meetings.artifacts(id, 'enhanced_notes').first;
      return store.refreshArtifactSource(accepted.id);
    });
    if (source != null) indexSource(source);
    mapping.captureSuccess(
      notes: queries.body(id),
      enhancedNotes: enhancement.body,
    );
    _noteEnhancements.remove(id);
    changed();
  }

  bool _restoreFailure(_NoteRun run, Object error) {
    final id = run.id, enhancement = run.enhancement;
    final previous = run.previous;
    final current = enhancement.current;
    enhancement.active = false;
    if (!identical(_noteEnhancements[id], enhancement)) {
      enhancement.saveTimer?.cancel();
      return true;
    }
    if (_closed || !(current?.call() ?? true) || enhancement.cancelRequested) {
      enhancement.body = enhancement.restoreBody ?? previous;
      enhancement.status = '';
      _restoreNoteMapping(id, queries.body(id), enhancement.body);
      enhancement.saveTimer?.cancel();
      store.restoreMeetingEnhancedDraft(id, enhancement.body);
      if (_closed || !(current?.call() ?? true)) {
        _noteEnhancements.remove(id);
      } else {
        _scheduleEnhancedDraft(id, enhancement);
      }
      if (!_closed) changed();
      return true;
    }
    enhancement.saveTimer?.cancel();
    enhancement.body = enhancement.restoreBody ?? previous;
    store.restoreMeetingEnhancedDraft(id, enhancement.body);
    _restoreNoteMapping(id, queries.body(id), enhancement.body);
    enhancement.status = error.toString();
    changed();
    return false;
  }

  void _settleRun(_NoteRun run, GenerationReservation? reservation) {
    final id = run.id, notes = run.notes, enhancement = run.enhancement;
    final mapping = run.mapping;
    final isLive = enhancement.isLive;
    if (enhancement.foregroundYielded &&
        !_closed &&
        identical(_noteEditMappings[id], mapping) &&
        store.preference('liveEnhance', 'true') == 'true') {
      _scheduleEnhaseRetry(
        id,
        isLive: true,
        targetBulletIndices: _pendingNoteTargets.remove(id),
      );
    } else if (isLive &&
        !_closed &&
        identical(_noteEditMappings[id], mapping) &&
        store.preference('liveEnhance', 'true') == 'true') {
      if (_pendingNoteTargets.isNotEmpty) {
        final next = _pendingNoteTargets.entries.first;
        _pendingNoteTargets.remove(next.key);
        // The child stream and persistence have settled. Register the next
        // producer synchronously before dropping this producer's accounting;
        // settling this token again below cannot release its successor.
        reservation?.settle();
        _requestAutomaticNoteEnhancement(next.key, targets: next.value);
      } else if (isLive) {
        final currentNotes = queries.body(id);
        if (currentNotes != notes.body &&
            hasEnhanceableNoteScribbles(currentNotes)) {
          scheduleEnhancement(id);
        }
      }
    }
    _activeEnhancements--;
    _running.remove(enhancement);
    reservation?.settle();
    if (!enhancement.finished.isCompleted) enhancement.finished.complete();
    changed();
  }

  void _scheduleEnhancedDraft(int id, _NoteEnhancement enhancement) {
    if (_closed) return;
    enhancement.saveTimer?.cancel();
    enhancement.saveTimer = domain.createTimer(const Duration(seconds: 1), () {
      enhancement.saveTimer = null;
      if (_closed ||
          !(enhancement.current?.call() ?? true) ||
          !identical(_noteEnhancements[id], enhancement)) {
        return;
      }
      try {
        store.saveMeetingEnhancedDraft(id, enhancement.body);
        if (!enhancement.active && enhancement.status.isEmpty) {
          _noteEnhancements.remove(id);
        }
      } catch (error) {
        enhancement.status = 'Unable to save enhanced notes: $error';
      }
      changed();
    });
  }

  void _scheduleEnhaseRetry(
    int id, {
    Set<int>? targetBulletIndices,
    bool isLive = false,
  }) {
    if (_closed) return;
    _enhance.remove(id)?.cancel();
    _enhance[id] = domain.createTimer(
      const Duration(seconds: 3),
      () => unawaited(
        enhanceNotes(
          id,
          deferWhenBusy: true,
          isLive: isLive,
          targetBulletIndices: targetBulletIndices,
        ).catchError((Object error) {
          capture.state = 'Note enhancement: $error';
          changed();
        }),
      ),
    );
  }
}

final class _NoteRun {
  _NoteRun({
    required this.id,
    required this.notes,
    required this.transcript,
    required this.revision,
    required this.enhancement,
    required this.previous,
    required this.mapping,
    required this.forceRegenerate,
    required Set<int>? targetBulletIndices,
  }) : targetBulletIndices = targetBulletIndices == null
           ? null
           : Set.unmodifiable(targetBulletIndices);
  final int id, revision;
  final MeetingNoteData notes;
  final String transcript, previous;
  final _NoteEnhancement enhancement;
  final ReferenceNoteEditMapping mapping;
  final bool forceRegenerate;
  final Set<int>? targetBulletIndices;
  final failedBatches = <List<int>>[];
}

class _NoteEnhancement {
  _NoteEnhancement(
    this.requestId,
    this.body, {
    this.current,
    this.isLive = false,
  });
  final bool isLive;
  bool foregroundYielded = false;
  final finished = Completer<void>();
  final bool Function()? current;
  final String requestId;
  String body, status = '';
  String? restoreBody;
  bool active = true, cancelRequested = false;
  int? activeIndex;
  Timer? saveTimer;
  String? child;
  NativeRuntime? runtime;
  Map<String, Object?> get state => {
    'request_id': requestId,
    'body': body,
    'status': status,
    'active': active,
    'cancel_requested': cancelRequested,
    'active_index': activeIndex,
  };
}
