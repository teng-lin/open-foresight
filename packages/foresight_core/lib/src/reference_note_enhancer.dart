import 'dart:async';

import 'reference_note_enhancement.dart';
import 'reference_note_enhancement_context.dart';
import 'reference_note_enhancement_merge.dart';
import 'reference_note_enhancement_plan.dart';
import 'reference_note_enhancement_prompt.dart';
import 'reference_note_enhancement_ranking.dart';
import 'reference_note_transcript_cache.dart';

/// Original conversation settings requested by the producer. maxInputTokens is
/// serialized configuration, not an output budget or a locally enforced limit.
class NoteEnhancementConversationSettings {
  const NoteEnhancementConversationSettings({this.stopTokenIds});

  final int maxInputTokens = 2048;
  final List<List<int>>? stopTokenIds;
}

abstract interface class NoteEnhancementConversation {
  /// Each event contains incremental response text, not a cumulative snapshot.
  Stream<String> sendMessageStream(String prompt);
  Future<void> cancelProcess();
  Future<void> close();
}

/// Runtime-independent reconstruction of NotesEnhancer.enhanceStream.
/// Adapters own service recovery and transcript-cache fallback preparation.
class ReferenceNoteEnhancer {
  ReferenceNoteEnhancer({
    required this.ensureReady,
    required this.loadEmbeddedTranscript,
    required this.createConversation,
    this.computeEmbedding,
    this.encodeStopTokens,
    this.logBatchError,
    this.checkCurrent,
    this.onBatchFailure,
  });

  final Future<void> Function() ensureReady;
  final Future<List<EmbeddedNoteTranscriptChunk>> Function()
  loadEmbeddedTranscript;
  final Future<NoteEnhancementConversation> Function(
    NoteEnhancementConversationSettings settings,
  )
  createConversation;
  final Future<List<double>> Function(String text)? computeEmbedding;
  final Future<List<int>?> Function(String text)? encodeStopTokens;
  final void Function(Object error, StackTrace stack)? logBatchError;
  final void Function()? checkCurrent;
  final void Function(List<int> noteIndices, Object error)? onBatchFailure;

  Future<T> _whileCurrent<T>(Future<T> pending) async {
    if (checkCurrent == null) return pending;
    final interrupted = Completer<T>();
    final monitor = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (interrupted.isCompleted) return;
      try {
        checkCurrent!();
      } catch (error, stack) {
        interrupted.completeError(error, stack);
      }
    });
    try {
      return await Future.any([pending, interrupted.future]);
    } finally {
      monitor.cancel();
    }
  }

  Stream<String> enhance({
    required String notes,
    Map<int, String>? existingEnhancedBullets,
    Set<int>? targetBulletIndices,
    bool updateExistingWithTranscript = false,
    bool isLive = false,
    bool concise = false,
    void Function(int? index)? onActiveIndexChanged,
  }) async* {
    checkCurrent?.call();
    yield 'Evaluating notes...';
    final plan = planNoteEnhancement(
      notes: notes,
      existingEnhancedBullets: existingEnhancedBullets,
      targetBulletIndices: targetBulletIndices,
      updateExistingWithTranscript: updateExistingWithTranscript,
    );
    if (plan.originalNotes.isEmpty) {
      yield '';
      return;
    }
    if (plan.initialEnhancedBody case final body?) yield body;
    final merge = NoteEnhancementMerge(
      originalNotes: plan.originalNotes,
      pendingNotes: plan.pendingNotes,
      previousEnhanced: plan.acceptedEnhancements,
      isLive: isLive,
    );
    if (plan.pendingNotes.isEmpty) {
      if (plan.skippedNotes.isNotEmpty ||
          plan.acceptedEnhancements.isNotEmpty) {
        yield merge.finalBody;
      }
      return;
    }
    yield 'Scanning the transcripts...';
    await ensureReady();
    checkCurrent?.call();
    final embeddedChunks = await _whileCurrent(loadEmbeddedTranscript());
    checkCurrent?.call();
    final chunks = embeddedChunks.map((chunk) => chunk.text).toList();
    final embed = computeEmbedding;
    final vectors = embed == null
        ? [for (final _ in plan.pendingNotes) <double>[]]
        : await _whileCurrent(
            Future.wait([
              for (final note in plan.pendingNotes) embed(note.text),
            ]),
          );
    final refs = selectNoteEnhancementExcerptRefs(
      noteEmbeddings: vectors,
      chunkEmbeddings: embeddedChunks.map((chunk) => chunk.embedding).toList(),
    );
    final uncovered = selectUncoveredNoteEnhancementExcerpts(chunks, refs);
    final encoder = encodeStopTokens;
    final stopIds = encoder == null ? null : await encoder('</output>');
    final settings = NoteEnhancementConversationSettings(
      stopTokenIds: stopIds == null || stopIds.isEmpty ? null : [stopIds],
    );
    final batches = clusterNoteEnhancementBatches(
      refs,
      plan.pendingNotes.length,
    );
    prioritizeNoteEnhancementBatches(
      batches,
      plan.pendingNotes,
      plan.acceptedEnhancements,
    );
    yield 'Structuring notes...';
    for (var batchIndex = 0; batchIndex < batches.length; batchIndex++) {
      checkCurrent?.call();
      final batch = batches[batchIndex];
      onActiveIndexChanged?.call(plan.pendingNotes[batch.first].originalIndex);
      final context = buildNoteEnhancementBatchContext(
        chunks: chunks,
        pendingNotes: plan.pendingNotes,
        selectedRefs: refs,
        batch: batch,
        previousEnhanced: merge.accepted,
        uncoveredChunks: uncovered,
        isLive: isLive,
        isLastBatch: batchIndex == batches.length - 1,
      );
      final conversation = await createConversation(settings);
      StreamIterator<String>? iterator;
      Future<void> cancelIterator() async {
        final active = iterator;
        iterator = null;
        if (active != null) await active.cancel();
      }

      try {
        final prompt = buildNoteEnhancementPrompt(
          relevantExcerpts: context.relevantExcerpts,
          shorthandNotes: context.shorthandNotes,
          uncoveredExcerpts: context.uncoveredExcerpts,
          includeMissedTopics: context.includeMissedTopics,
          concise: concise,
        );
        final response = StringBuffer();
        try {
          final active = StreamIterator(conversation.sendMessageStream(prompt));
          iterator = active;
          while (await active.moveNext()) {
            checkCurrent?.call();
            final delta = active.current;
            if (delta.isEmpty) continue;
            response.write(delta);
            final preview = merge.previewCleaned(
              cleanNoteEnhancementPreviewOutput(response.toString()),
              batch,
            );
            onActiveIndexChanged?.call(preview.activeIndex);
            yield preview.body;
            // The original emits the snapshot before checking raw stop markers.
            if (_stopMarkers.any(response.toString().contains)) {
              await conversation.cancelProcess();
              break;
            }
          }
        } finally {
          await cancelIterator();
        }
        final cleaned = cleanNoteEnhancementModelOutput(
          response.toString(),
        ).trim();
        final parsed = parseNoteEnhancementBatchOutput(cleaned, batch.length);
        if (parsed.notes.length < batch.length) {
          onBatchFailure?.call([
            for (final index in batch.skip(parsed.notes.length))
              plan.pendingNotes[index].originalIndex,
          ], StateError('Model omitted requested note enhancements'));
        }
        merge.acceptCleaned(cleaned, batch);
      } catch (error, stack) {
        checkCurrent?.call();
        onBatchFailure?.call([
          for (final index in batch) plan.pendingNotes[index].originalIndex,
        ], error);
        logBatchError?.call(error, stack);
        merge.failBatch(batch);
      } finally {
        // Cancellation during yield runs both finally blocks without accepting
        // or failing the batch. Iterator disposal precedes conversation disposal.
        // This is outside batch recovery: a close failure ends the producer,
        // without starting another batch or emitting its final merged body.
        // If recovery itself throws, a successful close preserves that error
        // and stack; a failing close replaces it using Dart finally semantics.
        await conversation.close();
      }
    }
    onActiveIndexChanged?.call(null);
    yield merge.finalBody;
  }
}

const _stopMarkers = ['</output>', '<turn|>', '<eos>', '<end_of_turn>'];
