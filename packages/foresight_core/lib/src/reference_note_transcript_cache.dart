import 'dart:async';
import 'dart:collection';

import 'reference_note_enhancement_chunking.dart';

typedef EmbeddedNoteTranscriptChunk = ({String text, List<double> embedding});

/// Reconstructs the original five-meeting transcript embedding cache.
///
/// Requests coalesce to the latest pending transcript while a sequential drain
/// is running. Every drain clears its running future in a finally block, while
/// an embedding failure still propagates to all callers sharing that future.
class ReferenceNoteTranscriptCache {
  ReferenceNoteTranscriptCache({
    required this.computeEmbedding,
    required this.currentIsLive,
    required this.loadSavedTranscript,
  });

  final Future<List<double>> Function(String text) computeEmbedding;
  final bool Function(int meetingId) currentIsLive;
  final Future<String> Function(int meetingId) loadSavedTranscript;
  final _entries = LinkedHashMap<int, _TranscriptEntry>();

  /// Discard ephemeral entries when the workspace or embedding model changes.
  int _epoch = 0;
  final _revisions = <int, int>{};

  void clear() {
    _epoch++;
    _entries.clear();
    _revisions.clear();
  }

  /// Port mutation ownership: a changed saved transcript must be read again.
  /// Old readers may finish, but cannot schedule text from the old revision.
  void invalidate(int meetingId) {
    _revisions[meetingId] = (_revisions[meetingId] ?? 0) + 1;
    _entries.remove(meetingId);
  }

  _TranscriptEntry _entryFor(int meetingId) {
    final entry = _entries.remove(meetingId) ?? _TranscriptEntry();
    if (_entries.length >= 5) _entries.remove(_entries.keys.first);
    _entries[meetingId] = entry;
    return entry;
  }

  Future<void> schedule(int meetingId, String text, {required bool isLive}) {
    final entry = _entryFor(meetingId);
    entry.pending = (text: text, isLive: isLive);
    final running = entry.running;
    if (running != null) return running;
    final completion = Completer<void>();
    entry.running = completion.future;
    _drain(
      meetingId,
      entry,
    ).then(completion.complete, onError: completion.completeError);
    return completion.future;
  }

  Future<void> _drain(int meetingId, _TranscriptEntry entry) async {
    try {
      while (entry.pending != null) {
        final request = entry.pending!;
        entry.pending = null;
        final chunks = await _chunkAndEmbed(
          request.text,
          request.isLive,
          entry.chunks,
        );
        if (request.isLive == currentIsLive(meetingId)) {
          entry.isLive = request.isLive;
          entry.chunks = chunks;
        }
      }
    } finally {
      entry.running = null;
    }
  }

  Future<List<EmbeddedNoteTranscriptChunk>> _chunkAndEmbed(
    String text,
    bool isLive,
    List<EmbeddedNoteTranscriptChunk> previous,
  ) async {
    final reused = <String, List<double>>{
      for (final chunk in previous)
        if (chunk.embedding.isNotEmpty) chunk.text: chunk.embedding,
    };
    final chunks = <EmbeddedNoteTranscriptChunk>[];
    for (final text in chunkNoteEnhancementTranscript(text, isLive: isLive)) {
      final embedding = reused[text] ?? await computeEmbedding(text);
      chunks.add((text: text, embedding: embedding));
    }
    return chunks;
  }

  List<EmbeddedNoteTranscriptChunk> getCachedChunks(int meetingId) {
    final entry = _entries.remove(meetingId);
    if (entry == null) return const [];
    _entries[meetingId] = entry;
    return entry.chunks;
  }

  Future<List<EmbeddedNoteTranscriptChunk>> getEmbeddedChunks(
    int meetingId,
  ) async {
    final epoch = _epoch;
    final revision = _revisions[meetingId] ?? 0;
    bool current() =>
        epoch == _epoch && revision == (_revisions[meetingId] ?? 0);
    var entry = _entries[meetingId];
    if (currentIsLive(meetingId)) {
      if (entry == null) return [];
      final running = entry.running;
      if (running != null) await running;
      if (!current()) return [];
      return entry.isLive == true ? getCachedChunks(meetingId) : [];
    }
    if (entry == null ||
        entry.running != null ||
        entry.isLive != false ||
        entry.chunks.isEmpty ||
        entry.chunks.any((chunk) => chunk.embedding.isEmpty)) {
      final text = await loadSavedTranscript(meetingId);
      if (!current()) return [];
      if (text.trim().isEmpty) return [];
      final work = schedule(meetingId, text, isLive: false);
      await work;
      if (!current()) return [];
      entry = _entries[meetingId];
    }
    return entry?.isLive == false ? getCachedChunks(meetingId) : [];
  }
}

class _TranscriptEntry {
  bool? isLive;
  List<EmbeddedNoteTranscriptChunk> chunks = [];
  ({String text, bool isLive})? pending;
  Future<void>? running;
}
