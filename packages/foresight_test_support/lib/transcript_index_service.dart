import 'dart:convert';
import 'package:grpc/grpc.dart';
// ignore: implementation_imports
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
// ignore: implementation_imports
import 'package:foresight_core/src/generated/transcript_index.pbgrpc.dart'
    as wire;

/// Controlled wire peer for application producer tests. Native contracts retain
/// responsibility for real SQL/tokenizer/vector publication acceptance.
class ControlledTranscriptIndex extends wire.TranscriptIndexServiceBase {
  Future<void> Function(ServiceCall, wire.TranscriptDelta)? beforeApply;
  final requests = <wire.TranscriptDelta>[];
  final calls = <ServiceCall>[];
  final cursors = <String, wire.TranscriptCursor>{};
  final pieces = <String, Map<String, wire.TranscriptSegment>>{};
  final _last = <String, List<int>>{};
  int cursorReads = 0, embeddedBytes = 0, embeddedChunks = 0, receivedBytes = 0;
  bool failAfterCommitOnce = false;
  String key(wire.TranscriptKey value) =>
      '${value.channel.value}:${value.segmentId}';
  @override
  Future<wire.TranscriptCursor> getCursor(
    ServiceCall call,
    wire.TranscriptCursorRequest request,
  ) async {
    cursorReads++;
    return wire.TranscriptCursor.fromBuffer(
      (cursors[request.documentId] ?? wire.TranscriptCursor()).writeToBuffer(),
    );
  }

  @override
  Future<wire.TranscriptDeltaResult> applyDelta(
    ServiceCall call,
    wire.TranscriptDelta request,
  ) async {
    requests.add(request);
    calls.add(call);
    final bytes = request.writeToBuffer();
    receivedBytes += bytes.length;
    await beforeApply?.call(call, request);
    if (call.isCanceled) {
      throw GrpcError.cancelled('Controlled canceled producer');
    }
    final zero = request.revision - request.revision;
    final previous = cursors[request.documentId] ?? wire.TranscriptCursor();
    final old = _last[request.documentId];
    if (previous.exists &&
        previous.revision == request.revision &&
        old != null &&
        old.length == bytes.length &&
        List.generate(
          bytes.length,
          (i) => i,
        ).every((i) => old[i] == bytes[i])) {
      return wire.TranscriptDeltaResult(
        revision: request.revision,
        applied: false,
      );
    }
    if (previous.revision != request.expectedRevision ||
        (!request.reset &&
            previous.exists &&
            previous.workspaceEpoch != request.workspaceEpoch)) {
      throw GrpcError.aborted('Controlled cursor mismatch');
    }
    final current = request.reset
        ? <String, wire.TranscriptSegment>{}
        : pieces.putIfAbsent(request.documentId, () => {});
    var bytesEmbedded = 0, chunksEmbedded = 0;
    final cursor = wire.TranscriptCursor(
      exists: true,
      workspaceEpoch: request.workspaceEpoch,
      revision: request.revision,
      lastSegmentId: request.reset ? zero : previous.lastSegmentId,
    );
    for (final segment in request.upserts) {
      if (current[key(segment.key)]?.text != segment.text) {
        bytesEmbedded += utf8.encode(segment.text).length;
        chunksEmbedded++;
      }
      current[key(segment.key)] = wire.TranscriptSegment.fromBuffer(
        segment.writeToBuffer(),
      );
      if (segment.key.segmentId > cursor.lastSegmentId) {
        cursor.lastSegmentId = segment.key.segmentId;
      }
    }
    for (final deleted in request.deletes) {
      current.remove(key(deleted));
    }
    cursor.segmentCount = zero + current.length;
    pieces[request.documentId] = current;
    cursors[request.documentId] = cursor;
    _last[request.documentId] = bytes;
    embeddedBytes += bytesEmbedded;
    embeddedChunks += chunksEmbedded;
    if (failAfterCommitOnce) {
      failAfterCommitOnce = false;
      throw GrpcError.unavailable('Controlled response lost after commit');
    }
    return wire.TranscriptDeltaResult(
      revision: request.revision,
      applied: true,
      embeddedBytes: zero + bytesEmbedded,
      embeddedChunks: zero + chunksEmbedded,
    );
  }
}

/// Adapter for consumers whose held/error oracle lives on IndexDocument. Real
/// helper tests qualify incremental publication and bounded-work behavior.
class TranscriptIndexService extends wire.TranscriptIndexServiceBase {
  TranscriptIndexService(this.rag);
  final RagServiceBase rag;
  final _cursors = <String, wire.TranscriptCursor>{};
  final _segments = <String, Map<String, wire.TranscriptSegment>>{};

  @override
  Future<wire.TranscriptCursor> getCursor(
    ServiceCall call,
    wire.TranscriptCursorRequest request,
  ) async => _cursors[request.documentId] ?? wire.TranscriptCursor();

  @override
  Future<wire.TranscriptDeltaResult> applyDelta(
    ServiceCall call,
    wire.TranscriptDelta request,
  ) async {
    final previous = _cursors[request.documentId];
    if (!request.reset &&
        (previous?.revision != request.expectedRevision ||
            previous?.workspaceEpoch != request.workspaceEpoch)) {
      throw const GrpcError.aborted('Fixture transcript cursor changed');
    }
    final segments = <String, wire.TranscriptSegment>{
      if (!request.reset) ...?_segments[request.documentId],
    };
    String key(wire.TranscriptKey key) =>
        '${key.channel.value}:${key.segmentId}';
    for (final removed in request.deletes) {
      segments.remove(key(removed));
    }
    for (final segment in request.upserts) {
      segments[key(segment.key)] = segment;
    }
    final ordered = segments.values.toList()
      ..sort((a, b) => a.key.segmentId.compareTo(b.key.segmentId));
    final result = await rag.indexDocument(
      call,
      IndexRequest(
        documentId: request.documentId,
        content: ordered.map((segment) => segment.text).join('\n'),
      ),
    );
    if (!result.success) throw GrpcError.internal(result.errorMessage);
    // Preserve the same held ServiceCall and observe cancellation before ack.
    if (call.isCanceled) throw const GrpcError.cancelled();
    _segments[request.documentId] = segments;
    _cursors[request.documentId] = wire.TranscriptCursor(
      exists: true,
      workspaceEpoch: request.workspaceEpoch,
      revision: request.revision,
      lastSegmentId: ordered.isEmpty ? null : ordered.last.key.segmentId,
    );
    return wire.TranscriptDeltaResult(
      applied: true,
      revision: request.revision,
    );
  }
}
