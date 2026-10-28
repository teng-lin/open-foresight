import 'dart:async';

import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';

import '../../presentation/workspace_presentation.dart';

/// Implemented by the typed service adapter. Commands revalidate session and
/// media ownership; this widget never treats presentation eligibility as a lease.
/// Futures acknowledge control requests; subsequent playback/export snapshots
/// describe the actual operation. Partial saves carry explicit user consent.
abstract interface class MeetingAudioPlayerActions {
  Future<void> play(String sessionId);
  Future<void> pause(String sessionId);
  Future<void> seek(String sessionId, int playbackUs);
  Future<void> seekTranscript(AudioTranscriptSeekTarget target);
  Future<void> export(
    String sessionId,
    MeetingAudioExportFormat format, {
    required bool allowIncomplete,
  });
  Future<void> cancelExport(String sessionId);
  Future<void> retryTranscription(String sessionId);
  Future<void> retryCompression(String sessionId);
  Future<void> deleteRecording(String sessionId);
  Future<void> setRetainLossless(String sessionId, bool value);
}

class MeetingAudioPlayer extends StatefulWidget {
  const MeetingAudioPlayer({
    super.key,
    required this.session,
    required this.playback,
    required this.actions,
    this.transcriptTarget,
  });
  final AudioSessionPresentation session;
  final AudioPlaybackPresentation playback;
  final MeetingAudioPlayerActions actions;
  final AudioTranscriptSeekTarget? transcriptTarget;
  @override
  State<MeetingAudioPlayer> createState() => _MeetingAudioPlayerState();
}

class _MeetingAudioPlayerState extends State<MeetingAudioPlayer> {
  bool _busy = false;
  bool _confirmingDelete = false;
  int _request = 0;
  int? _dragUs;
  String _commandError = '';

  Future<void> _confirmDelete(AudioSessionPresentation session) async {
    final actions = widget.actions;
    setState(() => _confirmingDelete = true);
    late final bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete recording?'),
          content: const Text(
            'This recording’s audio will be removed. Your transcript will stay available.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete recording'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _confirmingDelete = false);
    }
    if (confirmed != true ||
        !mounted ||
        widget.session.id != session.id ||
        !widget.session.canDeleteRecording)
      return;
    await actions.deleteRecording(session.id);
  }

  @override
  void didUpdateWidget(MeetingAudioPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id) {
      // A late operation for the previous clip cannot modify this clip's UI.
      _request++;
      _busy = false;
      _dragUs = null;
      _commandError = '';
    }
  }

  Future<void> _perform(Future<void> Function() action, String failure) async {
    if (_busy) return;
    final request = ++_request;
    setState(() {
      _busy = true;
      _commandError = '';
    });
    try {
      await action();
    } catch (_) {
      if (mounted && request == _request)
        setState(() {
          _commandError = failure;
        });
    } finally {
      if (mounted && request == _request)
        setState(() {
          _busy = false;
          _dragUs = null;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final playback = widget.playback;
    final hasAudio =
        (session.availability == MeetingAudioAvailability.available ||
            session.availability == MeetingAudioAvailability.partial) &&
        session.durationUs > 0;
    final canPlay = session.canPlay && session.durationUs > 0;
    final canControl =
        canPlay &&
        !_busy &&
        playback.state != MeetingAudioPlaybackState.loading;
    final playing = playback.state == MeetingAudioPlaybackState.playing;
    final position = (_dragUs ?? playback.positionUs).clamp(
      0,
      session.durationUs.clamp(0, 1 << 62),
    );
    final target = widget.transcriptTarget;
    final canSeekTranscript =
        canControl &&
        target != null &&
        target.sessionId == session.id &&
        target.playbackUs >= 0 &&
        target.playbackUs < session.durationUs;
    final exporting = session.export.pending > 0 || session.export.running > 0;
    final partial = session.availability == MeetingAudioAvailability.partial;
    final canExport =
        session.exportFormats.isNotEmpty &&
        session.canExport &&
        hasAudio &&
        !_busy &&
        !exporting;
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: 'Meeting recording',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: workspaceBlue.withValues(alpha: .24),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(session, playback, theme),
              const SizedBox(height: 8),
              _playbackControls(session, position, canControl, playing),
              _statusMessages(session, hasAudio, partial, exporting, theme),
              _storageDetails(session, theme),
              if (session.canChangeRetention) _retentionControl(session),
              _actionButtons(
                session,
                canExport,
                partial,
                exporting,
                target,
                canSeekTranscript,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(
    AudioSessionPresentation session,
    AudioPlaybackPresentation playback,
    ThemeData theme,
  ) {
    return Row(
      children: [
        const Icon(Icons.graphic_eq, color: workspaceInk),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _title(session.physicalState),
            style: theme.textTheme.titleMedium,
          ),
        ),
        if ((_busy && !_confirmingDelete) ||
            (session.playbackSupported &&
                playback.state == MeetingAudioPlaybackState.loading))
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _playbackControls(
    AudioSessionPresentation session,
    int position,
    bool canControl,
    bool playing,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (session.playbackSupported)
          Row(
            children: [
              IconButton(
                tooltip: playing ? 'Pause audio' : 'Play audio',
                onPressed: canControl
                    ? () => unawaited(
                        _perform(
                          () => playing
                              ? widget.actions.pause(session.id)
                              : widget.actions.play(session.id),
                          'Couldn’t play this recording. Try again.',
                        ),
                      )
                    : null,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              Expanded(
                child: Slider(
                  value: position.toDouble(),
                  max: session.durationUs > 0
                      ? session.durationUs.toDouble()
                      : 1,
                  onChanged: canControl
                      ? (v) => setState(() {
                          _dragUs = v.round();
                        })
                      : null,
                  onChangeEnd: canControl
                      ? (v) => unawaited(
                          _perform(
                            () => widget.actions.seek(session.id, v.round()),
                            'Couldn’t move to this part of the recording. Try again.',
                          ),
                        )
                      : null,
                  semanticFormatterCallback: (v) =>
                      '${_time(v.round())} of ${_time(session.durationUs)}',
                  label: _time(position),
                ),
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            session.playbackSupported
                ? '${_time(position)} / ${_time(session.durationUs)}'
                : _time(session.durationUs),
            semanticsLabel: session.playbackSupported
                ? '${_time(position)} of ${_time(session.durationUs)}'
                : 'Recording length ${_time(session.durationUs)}',
          ),
        ),
      ],
    );
  }

  Widget _statusMessages(
    AudioSessionPresentation session,
    bool hasAudio,
    bool partial,
    bool exporting,
    ThemeData theme,
  ) {
    final playback = widget.playback;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!session.playbackSupported && hasAudio)
          const Text('Audio playback is unavailable in this app session.'),
        if (session.availability == MeetingAudioAvailability.pending)
          const Text('Preparing your recording…'),
        if (session.availability == MeetingAudioAvailability.none)
          const Text('No saved audio yet.'),
        if (session.availability == MeetingAudioAvailability.missing)
          const Text('This recording’s audio is unavailable.'),
        if (partial || session.hasGaps)
          Text(
            session.playbackSupported
                ? 'Some audio is unavailable. You can listen to the available parts.'
                : 'Some audio is unavailable.',
          ),
        if (session.captureError == 'restored_without_audio')
          const Text('Audio is unavailable after restoring this meeting.')
        else if (session.captureError.isNotEmpty)
          const Text(
            'Recording stopped unexpectedly. Your saved audio is still shown here.',
          ),
        for (final source in session.sources)
          if (source.failedJobs > 0 || source.error.isNotEmpty)
            Text('${_source(source.source)} transcription needs attention.')
          else if (source.pendingDurationUs > 0 && !session.isRecording)
            Text(
              '${_source(source.source)} transcription is catching up: ${_time(source.pendingDurationUs)}.',
            ),
        if (session.compression.state == MeetingAudioWorkState.failed)
          const Text(
            'Audio compression needs attention. Available audio is kept.',
          )
        else if (!session.isRecording &&
            (session.compression.pending > 0 ||
                session.compression.running > 0))
          const Text('Saving space in the background…'),
        if (exporting)
          const Text('Saving audio…', key: ValueKey('audio-export-progress'))
        else if (session.export.state == MeetingAudioWorkState.failed)
          const Text('Couldn’t save the audio file. Try again.')
        else if (session.export.state == MeetingAudioWorkState.complete)
          const Text('Audio file saved.'),
        if (playback.state == MeetingAudioPlaybackState.failed)
          const Text('Couldn’t play this recording. Try again.'),
        if (_commandError.isNotEmpty)
          Semantics(
            liveRegion: true,
            child: Text(
              _commandError,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _storageDetails(AudioSessionPresentation session, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recording storage: ${_bytes(session.retainedBytes + session.stagingBytes)}',
            style: theme.textTheme.bodySmall,
          ),
          Text(
            '${_bytes(session.retainedBytes)} saved audio · '
            '${_bytes(session.stagingBytes)} additional copies',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _retentionControl(AudioSessionPresentation session) {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('Keep remaining originals'),
      subtitle: const Text(
        'Uses more storage. Already removed originals cannot be restored.',
      ),
      value: session.retainLossless,
      onChanged: _busy
          ? null
          : (value) => unawaited(
              _perform(
                () => widget.actions.setRetainLossless(session.id, value),
                'Couldn’t update the recording preference. Try again.',
              ),
            ),
    );
  }

  Widget _actionButtons(
    AudioSessionPresentation session,
    bool canExport,
    bool partial,
    bool exporting,
    AudioTranscriptSeekTarget? target,
    bool canSeekTranscript,
  ) {
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (session.canRetryTranscription)
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => unawaited(
                    _perform(
                      () => widget.actions.retryTranscription(session.id),
                      'Couldn’t retry transcription. Try again.',
                    ),
                  ),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry transcription'),
          ),
        if (session.canRetryCompression)
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => unawaited(
                    _perform(
                      () => widget.actions.retryCompression(session.id),
                      'Couldn’t retry compression. Try again.',
                    ),
                  ),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry compression'),
          ),
        if (session.canDeleteRecording)
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => unawaited(
                    _perform(
                      () => _confirmDelete(session),
                      'Couldn’t delete the recording. Try again.',
                    ),
                  ),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete recording'),
          ),
        if (session.exportFormats.isNotEmpty)
          _saveMenu(session, canExport, partial),
        if (exporting)
          TextButton(
            onPressed: _busy
                ? null
                : () => unawaited(
                    _perform(
                      () => widget.actions.cancelExport(session.id),
                      'Couldn’t cancel saving. Try again.',
                    ),
                  ),
            child: const Text('Cancel save'),
          ),
        if (target != null && session.playbackSupported)
          TextButton.icon(
            onPressed: canSeekTranscript
                ? () => unawaited(
                    _perform(
                      () => widget.actions.seekTranscript(target),
                      'This part of the recording is unavailable.',
                    ),
                  )
                : null,
            icon: const Icon(Icons.format_quote_rounded, size: 18),
            label: const Text('Listen to selected text'),
          ),
      ],
    );
  }

  Widget _saveMenu(
    AudioSessionPresentation session,
    bool canExport,
    bool partial,
  ) {
    final theme = Theme.of(context);
    return PopupMenuButton<MeetingAudioExportFormat>(
      tooltip: partial ? 'Save available audio' : 'Save audio',
      enabled: canExport,
      onSelected: (format) => unawaited(
        _perform(
          () => widget.actions.export(
            session.id,
            format,
            allowIncomplete: partial,
          ),
          'Couldn’t save the audio file. Try again.',
        ),
      ),
      itemBuilder: (context) => [
        PopupMenuItem<MeetingAudioExportFormat>(
          enabled: false,
          child: Text(
            'Saving re-encodes audio. Already compressed audio may lose some quality.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        const PopupMenuDivider(),
        for (final format in session.exportFormats)
          PopupMenuItem(
            value: format,
            child: Text(
              '${partial ? 'Available audio · ' : ''}${_format(format)}',
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.download_rounded,
              size: 20,
              color: canExport ? workspaceInk : theme.disabledColor,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                partial ? 'Save available audio' : 'Save audio',
                style: TextStyle(
                  color: canExport ? workspaceInk : theme.disabledColor,
                ),
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}

String _title(MeetingAudioPhysicalState state) => switch (state) {
  MeetingAudioPhysicalState.recording => 'Recording',
  MeetingAudioPhysicalState.paused => 'Recording paused',
  MeetingAudioPhysicalState.starting => 'Starting recording…',
  MeetingAudioPhysicalState.pausing => 'Pausing recording…',
  MeetingAudioPhysicalState.stopping => 'Finishing recording…',
  MeetingAudioPhysicalState.idle => 'Saved recording',
};
String _source(MeetingAudioSource source) => switch (source) {
  MeetingAudioSource.microphone => 'Microphone',
  MeetingAudioSource.playback => 'System audio',
};
String _format(MeetingAudioExportFormat format) => switch (format) {
  MeetingAudioExportFormat.opus => 'Opus · smaller file',
  MeetingAudioExportFormat.mp3 => 'MP3',
  MeetingAudioExportFormat.wav => 'WAV',
};
String _time(int us) {
  final seconds = us < 0 ? 0 : us ~/ 1000000;
  final minutes = seconds ~/ 60;
  return minutes >= 60
      ? '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'
      : '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

String _bytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB'];
  var value = bytes.clamp(0, 1 << 62).toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final formatted = value.toStringAsFixed(unit == 0 ? 0 : 1);
  return '${formatted.endsWith('.0') ? formatted.substring(0, formatted.length - 2) : formatted} ${units[unit]}';
}
