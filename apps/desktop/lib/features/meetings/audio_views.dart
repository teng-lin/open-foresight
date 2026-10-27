part of 'meetings_controller.dart';

extension _MeetingAudioViews on MeetingsController {
  MeetingAudioClientActions _meetingAudioActions(int id) {
    final identity =
        _reads.presentationIdentity ?? FeatureRequestIdentity.capture(d);
    return MeetingAudioClientActions(
      connection: () => d,
      identity: identity,
      alive: () => mounted && (meetingId ?? meetingPreviewId) == id,
      changed: () => _reads.audio.refresh(),
      chooseDestination: (format) => selectAudioExportDestination(
        current: () =>
            identity.isCurrent(d, alive: mounted) &&
            (meetingId ?? meetingPreviewId) == id,
        choosePath: () async => (await getSaveLocation(
          suggestedName: 'Meeting audio.${format.name}',
          acceptedTypeGroups: [
            XTypeGroup(
              label: format.name.toUpperCase(),
              extensions: [format.name],
            ),
          ],
        ))?.path,
        exists: (path) async =>
            await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound,
        confirmOverwrite: () async =>
            await _dialogs.showInputDialog<bool>(
              builder: (context) => AlertDialog(
                title: const Text('Replace this audio file?'),
                content: const Text(
                  'The file you selected already exists. Replacing it will overwrite its contents.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Replace'),
                  ),
                ],
              ),
            ) ??
            false,
      ),
    );
  }

  ValueChanged<int>? _audioTranscriptListener(int id) {
    final page = _reads.audio.page;
    if (page?.supported != true ||
        page!.meeting.availability == MeetingAudioAvailability.missing ||
        page.meeting.availability == MeetingAudioAvailability.none)
      return null;
    final actions = _meetingAudioActions(id);
    return (transcriptId) => unawaited(
      _operations.run(() => actions.listenToTranscript(transcriptId)),
    );
  }

  Widget meetingAudioPanel(int id) => MeetingAudioPanel(
    page: _reads.audio.page,
    sessions: _reads.audio.sessions,
    actions: _meetingAudioActions(id),
    onMore: () => unawaited(_reads.audio.loadMore()),
    hasMore: _reads.audio.nextAfterId != null,
    loading: _reads.audio.loading,
    problem: _reads.audio.problem,
    onRetry: () => unawaited(_reads.audio.refresh()),
  );
}
