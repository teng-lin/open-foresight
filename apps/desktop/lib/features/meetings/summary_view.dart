part of 'meetings_controller.dart';

extension _SummaryView on MeetingsController {
  Widget meetingSummaryPanel(int id, {bool actions = false}) {
    if (actions) return meetingActionsPanel(id);
    final identity = FeatureRequestIdentity.capture(d);
    final fromPreview = meetingId == null;
    final kind = actions ? 'actions' : 'summary';
    final title = actions ? 'Action items' : 'Summary';
    final versions = _reads.artifacts(id, kind);
    final artifact = versions.firstOrNull;
    final summary = actions ? null : d.capturePresentation.summary(id);
    final active = summary?.active == true;
    final preview = summary?.preview ?? '';
    final manifest = artifact?.manifest;
    final clipped = manifest != null && manifest['reduction_clipped'] == true;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Generate $title',
                onPressed:
                    active ||
                        _operations.busy ||
                        _chat.asking ||
                        meetingEnhancing
                    ? null
                    : () => _runMeetingAction(
                        id,
                        identity,
                        (current) => generateMeeting(
                          kind,
                          id: id,
                          workspaceEpoch: identity.workspaceEpoch,
                          current: current,
                        ),
                        preview: fromPreview,
                      ),
                icon: const Icon(Icons.auto_awesome),
              ),
              if (active)
                IconButton(
                  tooltip: 'Cancel summary',
                  onPressed: () => unawaited(
                    d
                        .command(Operation.meetingsCancelSummary, {'id': id})
                        .catchError(_operations.reportAsyncError),
                  ),
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              if (artifact != null)
                IconButton(
                  tooltip: 'Copy $title',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: artifact.body)),
                  icon: const Icon(Icons.copy_outlined),
                ),
              if (artifact != null)
                IconButton(
                  tooltip: 'Edit $title',
                  onPressed: active
                      ? null
                      : () => unawaited(
                          editArtifact(
                            artifact,
                          ).catchError(_operations.reportAsyncError),
                        ),
                  icon: const Icon(Icons.edit_outlined),
                ),
            ],
          ),
        ),
        if (active) ...[
          LinearProgressIndicator(
            value: (summary?.total ?? 0) > 0
                ? ((summary?.completed ?? 0) / summary!.total).clamp(0.0, 1.0)
                : null,
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(switch (summary?.phase) {
              'mapping' =>
                'Summarizing transcript ${summary?.completed}/${summary?.total}',
              'reducing' => 'Combining meeting topics…',
              'updating' => 'Updating the meeting brief…',
              'summarizing' => 'Writing the meeting brief…',
              _ => 'Preparing the meeting summary…',
            }),
          ),
        ],
        Expanded(
          child: active && preview.isNotEmpty
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: GeneratedContent(
                    preview,
                    openLink: _host.environment.openUri,
                    fontSize: _chat.answerFontSize,
                  ),
                )
              : artifact == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Generate ${title.toLowerCase()} from the meeting transcript.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xff87a8b7),
                        fontSize: 17,
                      ),
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (artifact.inputRevision < (_reads.revision(id) ?? 0))
                        const Text('Out of date — regenerate'),
                      if (clipped)
                        const Text(
                          'This summary used shortened excerpts. Review the transcript for full context.',
                        ),
                      GeneratedContent(
                        artifact.body,
                        openLink: _host.environment.openUri,
                        fontSize: _chat.answerFontSize,
                      ),
                      if (versions.length > 1)
                        ExpansionTile(
                          title: const Text('Previous versions'),
                          children: [
                            for (final previous in versions.skip(1))
                              ListTile(
                                title: GeneratedContent(
                                  previous.body,
                                  openLink: _host.environment.openUri,
                                ),
                                trailing: IconButton(
                                  tooltip: 'Edit previous version',
                                  onPressed: () => unawaited(
                                    editArtifact(
                                      previous,
                                    ).catchError(_operations.reportAsyncError),
                                  ),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
