import '../client_contract.dart';
import '../audio_presentation.dart';

final class RecordingsReadInput extends ClientArguments {
  const RecordingsReadInput({
    super.envelope,
    required this.meetingId,
    this.afterSessionId = '',
    this.limit = 32,
  });
  final int meetingId;
  final String afterSessionId;
  final int limit;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'meeting_id': meetingId,
    'after_session_id': afterSessionId,
    'limit': limit,
  });
}

final class RecordingsTranscriptTargetInput extends ClientArguments {
  const RecordingsTranscriptTargetInput({
    super.envelope,
    required this.transcriptId,
  });
  final int transcriptId;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({'transcript_id': transcriptId});
}

final class RecordingsPlayInput extends ClientArguments {
  const RecordingsPlayInput({super.envelope, required this.sessionId});
  final String sessionId;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'session_id': sessionId});
}

final class RecordingsPauseAudioInput extends ClientArguments {
  const RecordingsPauseAudioInput({super.envelope, required this.sessionId});
  final String sessionId;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'session_id': sessionId});
}

final class RecordingsSeekInput extends ClientArguments {
  const RecordingsSeekInput({
    super.envelope,
    required this.sessionId,
    required this.playbackUs,
  });
  final String sessionId;
  final int playbackUs;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({'session_id': sessionId, 'playback_us': playbackUs});
}

final class RecordingsSeekTranscriptInput extends ClientArguments {
  const RecordingsSeekTranscriptInput({
    super.envelope,
    required this.sessionId,
    required this.transcriptId,
  });
  final String sessionId;
  final int transcriptId;
  @override
  Map<String, dynamic> toWire() =>
      envelope.attach({'session_id': sessionId, 'transcript_id': transcriptId});
}

final class RecordingsAuthorizeExportDestinationInput extends ClientArguments {
  const RecordingsAuthorizeExportDestinationInput({
    super.envelope,
    required this.sessionId,
    required this.format,
    required this.outputPath,
    required this.overwrite,
    required this.allowIncomplete,
  });
  final String sessionId;
  final MeetingAudioExportFormat format;
  final String outputPath;
  final bool overwrite;
  final bool allowIncomplete;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'session_id': sessionId,
    'format': format.name,
    'output_path': outputPath,
    'overwrite': overwrite,
    'allow_incomplete': allowIncomplete,
  });
}

final class RecordingsExportInput extends ClientArguments {
  const RecordingsExportInput({
    super.envelope,
    required this.sessionId,
    required this.format,
    required this.destinationToken,
    required this.overwrite,
    required this.allowIncomplete,
  });
  final String sessionId;
  final MeetingAudioExportFormat format;
  final String destinationToken;
  final bool overwrite;
  final bool allowIncomplete;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'session_id': sessionId,
    'format': format.name,
    'destination_token': destinationToken,
    'overwrite': overwrite,
    'allow_incomplete': allowIncomplete,
  });
}

final class RecordingsCancelExportInput extends ClientArguments {
  const RecordingsCancelExportInput({super.envelope, required this.sessionId});
  final String sessionId;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'session_id': sessionId});
}

final class RecordingsDeleteInput extends ClientArguments {
  const RecordingsDeleteInput({super.envelope, required this.sessionId});
  final String sessionId;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'session_id': sessionId});
}

final class RecordingsSetRetainLosslessInput extends ClientArguments {
  const RecordingsSetRetainLosslessInput({
    super.envelope,
    required this.sessionId,
    required this.retainLossless,
  });
  final String sessionId;
  final bool retainLossless;
  @override
  Map<String, dynamic> toWire() => envelope.attach({
    'session_id': sessionId,
    'retain_lossless': retainLossless,
  });
}

final class RecordingsRetryTranscriptionInput extends ClientArguments {
  const RecordingsRetryTranscriptionInput({
    super.envelope,
    required this.sessionId,
  });
  final String sessionId;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'session_id': sessionId});
}

final class RecordingsRetryCompressionInput extends ClientArguments {
  const RecordingsRetryCompressionInput({
    super.envelope,
    required this.sessionId,
  });
  final String sessionId;
  @override
  Map<String, dynamic> toWire() => envelope.attach({'session_id': sessionId});
}
