import 'package:foresight_core/desktop.dart';
import '../../feature_request_identity.dart';
import 'audio_player.dart';

final class AudioExportSelection {
  const AudioExportSelection(this.outputPath, {required this.overwrite});
  final String outputPath;
  final bool overwrite;
}

/// Native destination selection is injected; only its chosen output is sent to
/// the protected grant operation. No audio input paths cross this boundary.
final class MeetingAudioClientActions implements MeetingAudioPlayerActions {
  MeetingAudioClientActions({
    required this.connection,
    required this.identity,
    required this.alive,
    required this.chooseDestination,
    required this.changed,
  });
  final DesktopConnection Function() connection;
  final FeatureRequestIdentity identity;
  final bool Function() alive;
  final Future<AudioExportSelection?> Function(MeetingAudioExportFormat)
  chooseDestination;
  final Future<void> Function() changed;
  bool _current() => identity.isCurrent(connection(), alive: alive());
  ClientEnvelope get _envelope =>
      ClientEnvelope(workspaceEpoch: WireField(identity.workspaceEpoch));
  Future<T> _call<Q extends ClientArguments, T>(
    OperationDescriptor<Q, T> descriptor,
    Q input,
  ) async {
    final value = await descriptor.sendCurrent(connection(), input, _current);
    if (!_current())
      throw RpcError(RpcErrorCode.cancelled, 'Audio operation cancelled');
    await changed();
    return value;
  }

  @override
  Future<void> play(String sessionId) => _call(
    recordingsPlayDescriptor,
    RecordingsPlayInput(sessionId: sessionId, envelope: _envelope),
  );
  @override
  Future<void> pause(String sessionId) => _call(
    recordingsPauseAudioDescriptor,
    RecordingsPauseAudioInput(sessionId: sessionId, envelope: _envelope),
  );
  @override
  Future<void> seek(String sessionId, int playbackUs) => _call(
    recordingsSeekDescriptor,
    RecordingsSeekInput(
      sessionId: sessionId,
      playbackUs: playbackUs,
      envelope: _envelope,
    ),
  );
  @override
  Future<void> seekTranscript(AudioTranscriptSeekTarget target) => _call(
    recordingsSeekTranscriptDescriptor,
    RecordingsSeekTranscriptInput(
      sessionId: target.sessionId,
      transcriptId: target.transcriptId,
      envelope: _envelope,
    ),
  );
  Future<void> listenToTranscript(int transcriptId) async {
    final target = await recordingsTranscriptTargetDescriptor.sendCurrent(
      connection(),
      RecordingsTranscriptTargetInput(
        transcriptId: transcriptId,
        envelope: _envelope,
      ),
      _current,
    );
    if (!_current()) return;
    if (target == null)
      throw RpcError(
        RpcErrorCode.notFound,
        'No saved audio is linked to this text.',
      );
    await seekTranscript(target);
  }

  @override
  Future<void> cancelExport(String sessionId) => _call(
    recordingsCancelExportDescriptor,
    RecordingsCancelExportInput(sessionId: sessionId, envelope: _envelope),
  );
  @override
  Future<void> retryTranscription(String sessionId) => _call(
    recordingsRetryTranscriptionDescriptor,
    RecordingsRetryTranscriptionInput(
      sessionId: sessionId,
      envelope: _envelope,
    ),
  );
  @override
  Future<void> retryCompression(String sessionId) => _call(
    recordingsRetryCompressionDescriptor,
    RecordingsRetryCompressionInput(sessionId: sessionId, envelope: _envelope),
  );
  @override
  Future<void> deleteRecording(String sessionId) => _call(
    recordingsDeleteDescriptor,
    RecordingsDeleteInput(sessionId: sessionId, envelope: _envelope),
  );
  @override
  Future<void> setRetainLossless(String sessionId, bool value) => _call(
    recordingsSetRetainLosslessDescriptor,
    RecordingsSetRetainLosslessInput(
      sessionId: sessionId,
      retainLossless: value,
      envelope: _envelope,
    ),
  );
  @override
  Future<void> export(
    String sessionId,
    MeetingAudioExportFormat format, {
    required bool allowIncomplete,
  }) async {
    if (!_current()) return;
    final selected = await chooseDestination(format);
    if (selected == null || !_current()) return;
    final grant = await recordingsAuthorizeExportDestinationDescriptor
        .sendCurrent(
          connection(),
          RecordingsAuthorizeExportDestinationInput(
            sessionId: sessionId,
            format: format,
            outputPath: selected.outputPath,
            overwrite: selected.overwrite,
            allowIncomplete: allowIncomplete,
            envelope: _envelope,
          ),
          _current,
        );
    if (!_current()) return;
    await _call(
      recordingsExportDescriptor,
      RecordingsExportInput(
        sessionId: sessionId,
        format: format,
        destinationToken: grant.token,
        overwrite: selected.overwrite,
        allowIncomplete: allowIncomplete,
        envelope: _envelope,
      ),
    );
  }
}

/// Native picker and confirmation are independent asynchronous boundaries.
/// A selection change at any boundary retires the unfinished destination choice.
Future<AudioExportSelection?> selectAudioExportDestination({
  required Future<String?> Function() choosePath,
  required Future<bool> Function(String) exists,
  required Future<bool> Function() confirmOverwrite,
  required bool Function() current,
}) async {
  if (!current()) return null;
  final path = await choosePath();
  if (path == null || !current()) return null;
  final replacing = await exists(path);
  if (!current()) return null;
  final overwrite = replacing ? await confirmOverwrite() : false;
  if (!current() || (replacing && !overwrite)) return null;
  return AudioExportSelection(path, overwrite: overwrite);
}
