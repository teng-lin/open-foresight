part of 'meetings_controller.dart';

extension _MeetingAiViews on MeetingsController {
  bool _meetingActionCurrent(
    int id,
    FeatureRequestIdentity identity, {
    bool preview = false,
  }) =>
      (preview
          ? meetingId == null && meetingPreviewId == id
          : meetingId == id) &&
      identity.isCurrent(d, alive: mounted);

  Future<void> _runMeetingAction(
    int id,
    FeatureRequestIdentity identity,
    Future<void> Function(bool Function() current) action, {
    bool preview = false,
  }) async {
    bool current() => _meetingActionCurrent(id, identity, preview: preview);
    // An input event can already be queued when its rendered view retires.
    if (!current()) return;
    await runAction(() => action(current), selectionCurrent: current);
  }

  Widget meetingAnswerScope(int id, {required bool automatic}) {
    final identity = _reads.presentationIdentity;
    final key = automatic ? 'proactiveScope.$id' : 'answerScope.meeting:$id';
    final scope = _reads.preference(key, automatic ? 'meeting' : 'workspace');
    return MeetingAnswerScope(
      scope: scope,
      onChanged: identity == null || _operations.busy
          ? null
          : (value) => _runMeetingAction(id, identity, (current) async {
              if (value == 'selected') {
                final ids = await selectMeetingSources(
                  id,
                  'answerSourcesSelection',
                );
                if (ids == null) return;
                if (!current()) return;
                await preferencesSetDescriptor.sendCurrent(
                  d,
                  PreferencesSetInput(
                    key: 'answerSources.meeting:$id',
                    value: jsonEncode(ids),
                    envelope: ClientEnvelope(
                      workspaceEpoch: WireField(identity.workspaceEpoch),
                    ),
                  ),
                  current,
                );
                if (!current()) return;
                await preferencesSetDescriptor.sendCurrent(
                  d,
                  PreferencesSetInput(
                    key: 'answerSourcesSelection.$id',
                    value: jsonEncode(ids),
                    envelope: ClientEnvelope(
                      workspaceEpoch: WireField(identity.workspaceEpoch),
                    ),
                  ),
                  current,
                );
              }
              if (!current()) return;
              await preferencesSetDescriptor.sendCurrent(
                d,
                PreferencesSetInput(
                  key: key,
                  value: value!,
                  envelope: ClientEnvelope(
                    workspaceEpoch: WireField(identity.workspaceEpoch),
                  ),
                ),
                current,
              );
            }),
    );
  }

  MeetingRunPresentation? _workflow(int id, String kind) =>
      d.capturePresentation.workflow(id, kind);

  Widget _workflowProgress(int id, String kind) {
    final state = _workflow(id, kind);
    return MeetingWorkflowProgress(
      state: state,
      onCancel: () => unawaited(
        meetingsCancelGenerationDescriptor
            .send(
              d,
              MeetingsCancelGenerationInput(id: id, kind: WireField(kind)),
            )
            .catchError(_operations.reportAsyncError),
      ),
    );
  }

  Widget meetingActionsPanel(int id) {
    final identity = _reads.presentationIdentity;
    final tasks = _reads.tasks(id);
    final versions = _reads.artifacts(id, 'actions');
    final active = _workflow(id, 'actions')?.active == true;
    return MeetingActionsPanel(
      tasks: tasks,
      versions: versions,
      progress: _workflowProgress(id, 'actions'),
      openLink: _host.environment.openUri,
      onGenerate: identity == null || active || _operations.busy
          ? null
          : () => _runMeetingAction(id, identity, (current) async {
              await meetingsGenerateDescriptor.sendCurrent(
                d,
                MeetingsGenerateInput(
                  id: id,
                  kind: 'actions',
                  envelope: ClientEnvelope(
                    workspaceEpoch: WireField(identity.workspaceEpoch),
                  ),
                ),
                current,
              );
            }),
      onCopy: (text) => Clipboard.setData(ClipboardData(text: text)),
      onComplete: identity == null || active || _operations.busy
          ? null
          : (task, completed) =>
                _setTaskCompletion(id, task.id, identity, completed),
      onEdit: identity == null || active || _operations.busy
          ? null
          : (task) => unawaited(
              editMeetingTask(
                task,
                identity,
              ).catchError(_operations.reportAsyncError),
            ),
    );
  }

  Future<void> _setTaskCompletion(
    int meeting,
    int task,
    FeatureRequestIdentity identity,
    bool completed,
  ) => _runMeetingAction(meeting, identity, (current) async {
    await meetingsEditTaskDescriptor.sendCurrent(
      d,
      MeetingsEditTaskInput(
        id: task,
        status: WireField(completed ? 'completed' : 'open'),
        envelope: ClientEnvelope(
          workspaceEpoch: WireField(identity.workspaceEpoch),
        ),
      ),
      current,
    );
  });

  Future<void> editMeetingTask(
    MeetingTask task,
    FeatureRequestIdentity identity,
  ) async {
    final selectedMeeting = meetingId;
    if (task.meetingId != selectedMeeting) return;
    bool current() =>
        meetingId == selectedMeeting && identity.isCurrent(d, alive: mounted);
    if (!current()) return;
    final text = TextEditingController(text: task.task),
        owner = TextEditingController(text: task.owner ?? ''),
        due = TextEditingController(text: task.due ?? '');
    try {
      final save = await _dialogs.showInputDialog<bool>(
        builder: (dialog) => MeetingTaskEditor(
          text: text,
          owner: owner,
          due: due,
          onCancel: () => Navigator.pop(dialog, false),
          onSave: () => Navigator.pop(dialog, true),
        ),
      );
      if (save == true && current())
        await meetingsEditTaskDescriptor.sendCurrent(
          d,
          MeetingsEditTaskInput(
            id: task.id,
            task: WireField(text.text),
            owner: WireField(
              owner.text.trim().isEmpty ? null : owner.text.trim(),
            ),
            due: WireField(due.text.trim().isEmpty ? null : due.text.trim()),
            envelope: ClientEnvelope(
              workspaceEpoch: WireField(identity.workspaceEpoch),
            ),
          ),
          current,
        );
    } catch (_) {
      if (current()) rethrow;
    } finally {
      text.dispose();
      owner.dispose();
      due.dispose();
    }
  }

  Future<List<String>?> selectMeetingSources(int id, String preference) async {
    final identity = FeatureRequestIdentity.capture(d);
    final selectedMeeting = meetingId, preview = meetingPreviewId;
    bool current() =>
        identity.isCurrent(d, alive: mounted) &&
        meetingId == selectedMeeting &&
        meetingPreviewId == preview;
    final sources = await readCurrentMeeting(
      d.store,
      StoreReadQueries.sources(),
    );
    if (!current()) return null;
    final saved = await readCurrentMeeting(
      d.store,
      StoreReadQueries.preference('$preference.$id', '[]'),
    );
    if (!current()) return null;
    final all = sources
        .where((source) => !source.id.startsWith('meeting-preparation-'))
        .toList();
    final selected = (jsonDecode(saved) as List).cast<String>().toSet()
      ..retainAll(all.map((source) => source.id));
    if (!context.mounted) return null;
    return showDialog<List<String>>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => MeetingSourceSelection(
          sources: [
            for (final source in all)
              MeetingSourceChoice(source.id, source.title),
          ],
          selected: selected,
          onSelected: (id, value) => update(() {
            if (value) {
              selected.add(id);
            } else {
              selected.remove(id);
            }
          }),
          onCancel: () => Navigator.pop(dialog),
          onConfirm: () => Navigator.pop(dialog, selected.toList()),
        ),
      ),
    );
  }

  Future<void> generatePreparation(
    int id,
    FeatureRequestIdentity identity,
    bool Function() current,
  ) async {
    final sources = await selectMeetingSources(id, 'preparationSources');
    if (sources == null || !current()) return;
    await preferencesSetDescriptor.sendCurrent(
      d,
      PreferencesSetInput(
        key: 'preparationSources.$id',
        value: jsonEncode(sources),
        envelope: ClientEnvelope(
          workspaceEpoch: WireField(identity.workspaceEpoch),
        ),
      ),
      current,
    );
    if (!current()) return;
    await meetingsPrepareDescriptor.sendCurrent(
      d,
      MeetingsPrepareInput(
        id: id,
        sourceIds: sources,
        envelope: ClientEnvelope(
          workspaceEpoch: WireField(identity.workspaceEpoch),
        ),
      ),
      current,
    );
  }

  Widget meetingPreparationPanel(int id) {
    final identity = _reads.presentationIdentity;
    final versions = _reads.artifacts(id, 'preparation');
    final active = _workflow(id, 'preparation')?.active == true;
    final preview = _workflow(id, 'preparation')?.preview ?? '';
    return MeetingPreparationPanel(
      versions: versions,
      active: active,
      preview: preview,
      progress: _workflowProgress(id, 'preparation'),
      openLink: _host.environment.openUri,
      onGenerate: identity == null || active || _operations.busy
          ? null
          : () => _runMeetingAction(
              id,
              identity,
              (current) => generatePreparation(id, identity, current),
            ),
      onCopy: (text) => Clipboard.setData(ClipboardData(text: text)),
      onEdit: (artifact) => unawaited(
        editArtifact(artifact).catchError(_operations.reportAsyncError),
      ),
    );
  }
}
