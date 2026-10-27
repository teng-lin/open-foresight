import '../audio_presentation.dart';
import '../operation_registry.dart';
import '../operation_requests.dart';
import '../operations.dart';
import '../persistence/audio_queries.dart';
import '../rpc_error.dart';
import 'audio_application_port.dart';

/// RPC admission stays in ApplicationService. This module never accepts input
/// media paths, grants output access itself, or starts filesystem/model workers.
final class RecordingAudioOperations {
  RecordingAudioOperations({
    required this.port,
    required this.metadata,
    required this.callerIdentity,
    required this.workspaceEpoch,
  });
  final AudioApplicationPort? port;
  final AudioQueries metadata;
  final Object Function() callerIdentity;
  final String Function() workspaceEpoch;
  AudioApplicationPort get _port =>
      port ??
      (throw RpcError(
        RpcErrorCode.unavailable,
        'Recording audio controls are unavailable in this app session.',
      ));
  bool Function() _current(bool Function()? current) => current ?? () => true;
  Future<T> _fenced<T>(
    bool Function() current,
    Future<T> Function() action,
  ) async {
    if (!current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Audio operation cancelled');
    }
    final value = await action();
    if (!current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Audio operation cancelled');
    }
    return value;
  }

  List<OperationHandler> get handlers => [
    TypedOperationHandler<RecordingsReadRequest>(Operation.recordingsRead, (
      r, {
      current,
    }) async {
      final page = await _fenced(_current(current), () async {
        if (port case final owner?) {
          return owner.readMeeting(
            r.meetingId,
            afterSessionId: r.afterSessionId,
            limit: r.limit,
            current: _current(current),
          );
        }
        final sessions = metadata.sessions(
          r.meetingId,
          afterId: r.afterSessionId,
          limit: r.limit,
        );
        return AudioMeetingReadPage(
          meeting: metadata.meeting(r.meetingId),
          sessions: sessions,
          nextAfterId: sessions.length == r.limit ? sessions.last.id : null,
          supported: false,
        );
      });
      return page.toMap();
    }),
    TypedOperationHandler<RecordingsTranscriptTargetRequest>(
      Operation.recordingsTranscriptTarget,
      (r, {current}) async => (await _fenced(
        _current(current),
        () async =>
            port?.transcriptTarget(r.transcriptId, current: _current(current)),
      ))?.toMap(),
    ),
    TypedOperationHandler<RecordingsPlayRequest>(
      Operation.recordingsPlay,
      (r, {current}) => _fenced(
        _current(current),
        () => _port.play(r.sessionId, current: _current(current)),
      ),
    ),
    TypedOperationHandler<RecordingsPauseAudioRequest>(
      Operation.recordingsPauseAudio,
      (r, {current}) => _fenced(
        _current(current),
        () => _port.pauseAudio(r.sessionId, current: _current(current)),
      ),
    ),
    TypedOperationHandler<RecordingsSeekRequest>(
      Operation.recordingsSeek,
      (r, {current}) => _fenced(
        _current(current),
        () => _port.seek(r.sessionId, r.playbackUs, current: _current(current)),
      ),
    ),
    TypedOperationHandler<RecordingsSeekTranscriptRequest>(
      Operation.recordingsSeekTranscript,
      (r, {current}) => _fenced(
        _current(current),
        () => _port.seekTranscript(
          r.sessionId,
          r.transcriptId,
          current: _current(current),
        ),
      ),
    ),
    TypedOperationHandler<RecordingsCancelExportRequest>(
      Operation.recordingsCancelExport,
      (r, {current}) => _fenced(
        _current(current),
        () => _port.cancelExport(r.sessionId, current: _current(current)),
      ),
    ),
    TypedOperationHandler<RecordingsRetryTranscriptionRequest>(
      Operation.recordingsRetryTranscription,
      (r, {current}) => _fenced(
        _current(current),
        () => _port.retryTranscription(r.sessionId, current: _current(current)),
      ),
    ),
    TypedOperationHandler<RecordingsRetryCompressionRequest>(
      Operation.recordingsRetryCompression,
      (r, {current}) => _fenced(
        _current(current),
        () => _port.retryCompression(r.sessionId, current: _current(current)),
      ),
    ),
    TypedOperationHandler<RecordingsDeleteRequest>(
      Operation.recordingsDelete,
      (r, {current}) => _fenced(
        _current(current),
        () => _port.deleteRecording(r.sessionId, current: _current(current)),
      ),
    ),
    TypedOperationHandler<RecordingsSetRetainLosslessRequest>(
      Operation.recordingsSetRetainLossless,
      (r, {current}) => _fenced(
        _current(current),
        () => _port.setRetainLossless(
          r.sessionId,
          r.retainLossless,
          current: _current(current),
        ),
      ),
    ),
    TypedOperationHandler<RecordingsAuthorizeExportDestinationRequest>(
      Operation.recordingsAuthorizeExportDestination,
      (r, {current}) async => (await _fenced(
        _current(current),
        () => _port.authorizeExportDestination(
          sessionId: r.sessionId,
          callerIdentity: callerIdentity(),
          workspaceEpoch: workspaceEpoch(),
          format: r.format,
          outputPath: r.outputPath,
          overwrite: r.overwrite,
          allowIncomplete: r.allowIncomplete,
          current: _current(current),
        ),
      )).toMap(),
    ),
    TypedOperationHandler<RecordingsExportRequest>(
      Operation.recordingsExport,
      (r, {current}) async => (await _fenced(
        _current(current),
        () => _port.export(
          sessionId: r.sessionId,
          callerIdentity: callerIdentity(),
          workspaceEpoch: workspaceEpoch(),
          format: r.format,
          destinationToken: r.destinationToken,
          overwrite: r.overwrite,
          allowIncomplete: r.allowIncomplete,
          current: _current(current),
        ),
      )).toMap(),
    ),
  ];
}
