import '../operations.dart';
import '../audio_presentation.dart';
import 'request_context.dart';

abstract class RecordingAudioRequest extends OperationRequest {
  const RecordingAudioRequest(super.context);
}

final class RecordingsReadRequest extends RecordingAudioRequest {
  RecordingsReadRequest._(
    super.context,
    this.meetingId,
    this.afterSessionId,
    this.limit,
  );
  final int meetingId;
  final String afterSessionId;
  final int limit;
  @override
  Operation get operation => Operation.recordingsRead;
  factory RecordingsReadRequest.decode(OperationRequestContext context) {
    final values = Operation.recordingsRead.descriptor.arguments.decode(
      context.rawArguments,
    );
    return RecordingsReadRequest._(
      context,
      values.value<int>('meeting_id'),
      values.value<String>('after_session_id'),
      values.value<int>('limit'),
    );
  }
}

final class RecordingsTranscriptTargetRequest extends RecordingAudioRequest {
  RecordingsTranscriptTargetRequest._(super.context, this.transcriptId);
  final int transcriptId;
  @override
  Operation get operation => Operation.recordingsTranscriptTarget;
  factory RecordingsTranscriptTargetRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation.recordingsTranscriptTarget.descriptor.arguments
        .decode(context.rawArguments);
    return RecordingsTranscriptTargetRequest._(
      context,
      values.value<int>('transcript_id'),
    );
  }
}

final class RecordingsPlayRequest extends RecordingAudioRequest {
  RecordingsPlayRequest._(super.context, this.sessionId);
  final String sessionId;
  @override
  Operation get operation => Operation.recordingsPlay;
  factory RecordingsPlayRequest.decode(OperationRequestContext context) {
    final values = Operation.recordingsPlay.descriptor.arguments.decode(
      context.rawArguments,
    );
    return RecordingsPlayRequest._(context, values.value<String>('session_id'));
  }
}

final class RecordingsPauseAudioRequest extends RecordingAudioRequest {
  RecordingsPauseAudioRequest._(super.context, this.sessionId);
  final String sessionId;
  @override
  Operation get operation => Operation.recordingsPauseAudio;
  factory RecordingsPauseAudioRequest.decode(OperationRequestContext context) {
    final values = Operation.recordingsPauseAudio.descriptor.arguments.decode(
      context.rawArguments,
    );
    return RecordingsPauseAudioRequest._(
      context,
      values.value<String>('session_id'),
    );
  }
}

final class RecordingsSeekRequest extends RecordingAudioRequest {
  RecordingsSeekRequest._(super.context, this.sessionId, this.playbackUs);
  final String sessionId;
  final int playbackUs;
  @override
  Operation get operation => Operation.recordingsSeek;
  factory RecordingsSeekRequest.decode(OperationRequestContext context) {
    final values = Operation.recordingsSeek.descriptor.arguments.decode(
      context.rawArguments,
    );
    return RecordingsSeekRequest._(
      context,
      values.value<String>('session_id'),
      values.value<int>('playback_us'),
    );
  }
}

final class RecordingsSeekTranscriptRequest extends RecordingAudioRequest {
  RecordingsSeekTranscriptRequest._(
    super.context,
    this.sessionId,
    this.transcriptId,
  );
  final String sessionId;
  final int transcriptId;
  @override
  Operation get operation => Operation.recordingsSeekTranscript;
  factory RecordingsSeekTranscriptRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation.recordingsSeekTranscript.descriptor.arguments
        .decode(context.rawArguments);
    return RecordingsSeekTranscriptRequest._(
      context,
      values.value<String>('session_id'),
      values.value<int>('transcript_id'),
    );
  }
}

final class RecordingsAuthorizeExportDestinationRequest
    extends OperationRequest {
  RecordingsAuthorizeExportDestinationRequest._(
    super.context,
    this.sessionId,
    this.format,
    this.outputPath,
    this.overwrite,
    this.allowIncomplete,
  );
  final String sessionId;
  final MeetingAudioExportFormat format;
  final String outputPath;
  final bool overwrite;
  final bool allowIncomplete;
  @override
  Operation get operation => Operation.recordingsAuthorizeExportDestination;
  factory RecordingsAuthorizeExportDestinationRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation
        .recordingsAuthorizeExportDestination
        .descriptor
        .arguments
        .decode(context.rawArguments);
    return RecordingsAuthorizeExportDestinationRequest._(
      context,
      values.value<String>('session_id'),
      MeetingAudioExportFormat.values.byName(values.value<String>('format')),
      values.value<String>('output_path'),
      values.value<bool>('overwrite'),
      values.value<bool>('allow_incomplete'),
    );
  }
}

final class RecordingsExportRequest extends RecordingAudioRequest {
  RecordingsExportRequest._(
    super.context,
    this.sessionId,
    this.format,
    this.destinationToken,
    this.overwrite,
    this.allowIncomplete,
  );
  final String sessionId;
  final MeetingAudioExportFormat format;
  final String destinationToken;
  final bool overwrite;
  final bool allowIncomplete;
  @override
  Operation get operation => Operation.recordingsExport;
  factory RecordingsExportRequest.decode(OperationRequestContext context) {
    final values = Operation.recordingsExport.descriptor.arguments.decode(
      context.rawArguments,
    );
    return RecordingsExportRequest._(
      context,
      values.value<String>('session_id'),
      MeetingAudioExportFormat.values.byName(values.value<String>('format')),
      values.value<String>('destination_token'),
      values.value<bool>('overwrite'),
      values.value<bool>('allow_incomplete'),
    );
  }
}

final class RecordingsCancelExportRequest extends RecordingAudioRequest {
  RecordingsCancelExportRequest._(super.context, this.sessionId);
  final String sessionId;
  @override
  Operation get operation => Operation.recordingsCancelExport;
  factory RecordingsCancelExportRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation.recordingsCancelExport.descriptor.arguments.decode(
      context.rawArguments,
    );
    return RecordingsCancelExportRequest._(
      context,
      values.value<String>('session_id'),
    );
  }
}

final class RecordingsDeleteRequest extends RecordingAudioRequest {
  RecordingsDeleteRequest._(super.context, this.sessionId);
  final String sessionId;
  @override
  Operation get operation => Operation.recordingsDelete;
  factory RecordingsDeleteRequest.decode(OperationRequestContext context) {
    final values = Operation.recordingsDelete.descriptor.arguments.decode(
      context.rawArguments,
    );
    return RecordingsDeleteRequest._(
      context,
      values.value<String>('session_id'),
    );
  }
}

final class RecordingsSetRetainLosslessRequest extends RecordingAudioRequest {
  RecordingsSetRetainLosslessRequest._(
    super.context,
    this.sessionId,
    this.retainLossless,
  );
  final String sessionId;
  final bool retainLossless;
  @override
  Operation get operation => Operation.recordingsSetRetainLossless;
  factory RecordingsSetRetainLosslessRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation.recordingsSetRetainLossless.descriptor.arguments
        .decode(context.rawArguments);
    return RecordingsSetRetainLosslessRequest._(
      context,
      values.value<String>('session_id'),
      values.value<bool>('retain_lossless'),
    );
  }
}

final class RecordingsRetryTranscriptionRequest extends RecordingAudioRequest {
  RecordingsRetryTranscriptionRequest._(super.context, this.sessionId);
  final String sessionId;
  @override
  Operation get operation => Operation.recordingsRetryTranscription;
  factory RecordingsRetryTranscriptionRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation.recordingsRetryTranscription.descriptor.arguments
        .decode(context.rawArguments);
    return RecordingsRetryTranscriptionRequest._(
      context,
      values.value<String>('session_id'),
    );
  }
}

final class RecordingsRetryCompressionRequest extends RecordingAudioRequest {
  RecordingsRetryCompressionRequest._(super.context, this.sessionId);
  final String sessionId;
  @override
  Operation get operation => Operation.recordingsRetryCompression;
  factory RecordingsRetryCompressionRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation.recordingsRetryCompression.descriptor.arguments
        .decode(context.rawArguments);
    return RecordingsRetryCompressionRequest._(
      context,
      values.value<String>('session_id'),
    );
  }
}
