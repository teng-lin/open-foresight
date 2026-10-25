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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Text('Answer sources: '),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: ['meeting', 'selected', 'workspace'].contains(scope)
                  ? scope
                  : 'meeting',
              items: const [
                DropdownMenuItem(value: 'meeting', child: Text('This meeting')),
                DropdownMenuItem(
                  value: 'selected',
                  child: Text('Selected local documents'),
                ),
                DropdownMenuItem(
                  value: 'workspace',
                  child: Text('Whole workspace'),
                ),
              ],
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
                              workspaceEpoch: WireField(
                                identity.workspaceEpoch,
                              ),
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
                              workspaceEpoch: WireField(
                                identity.workspaceEpoch,
                              ),
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
            ),
          ),
        ],
      ),
    );
  }

  MeetingRunPresentation? _workflow(int id, String kind) =>
      d.capturePresentation.workflow(id, kind);

  Widget _workflowProgress(int id, String kind) {
    final state = _workflow(id, kind);
    if (state?.active != true) {
      return state != null && state.error.isNotEmpty && !state.cancelled
          ? Padding(padding: const EdgeInsets.all(12), child: Text(state.error))
          : const SizedBox.shrink();
    }
    return Column(
      children: [
        const LinearProgressIndicator(),
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(switch (state?.phase) {
                  'extracting' =>
                    'Extracting commitments ${state?.completed}/${state?.total}…',
                  'documents' =>
                    'Preparing documents ${state?.completed}/${state?.total}…',
                  'synthesizing' => 'Writing the preparation brief…',
                  'reducing' => 'Combining document topics…',
                  _ => 'Planning meeting generation…',
                }),
              ),
            ),
            TextButton(
              onPressed: () => unawaited(
                meetingsCancelGenerationDescriptor
                    .send(
                      d,
                      MeetingsCancelGenerationInput(
                        id: id,
                        kind: WireField(kind),
                      ),
                    )
                    .catchError(_operations.reportAsyncError),
              ),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget meetingActionsPanel(int id) {
    final identity = _reads.presentationIdentity;
    final tasks = _reads.tasks(id);
    final versions = _reads.artifacts(id, 'actions');
    final active = _workflow(id, 'actions')?.active == true;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Expanded(
                child: Text('Action items', style: TextStyle(fontSize: 20)),
              ),
              IconButton(
                tooltip: 'Generate Action items',
                onPressed: identity == null || active || _operations.busy
                    ? null
                    : () => _runMeetingAction(id, identity, (current) async {
                        await meetingsGenerateDescriptor.sendCurrent(
                          d,
                          MeetingsGenerateInput(
                            id: id,
                            kind: 'actions',
                            envelope: ClientEnvelope(
                              workspaceEpoch: WireField(
                                identity.workspaceEpoch,
                              ),
                            ),
                          ),
                          current,
                        );
                      }),
                icon: const Icon(Icons.auto_awesome),
              ),
              if (versions.isNotEmpty)
                IconButton(
                  tooltip: 'Copy Action items',
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: versions.first.body),
                  ),
                  icon: const Icon(Icons.copy_outlined),
                ),
            ],
          ),
        ),
        _workflowProgress(id, 'actions'),
        Expanded(
          child: tasks.isEmpty
              ? versions.isEmpty
                    ? const Center(
                        child: Text(
                          'Extract commitments from the final transcript and your notes.',
                        ),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: GeneratedContent(
                          versions.first.body,
                          openLink: _host.environment.openUri,
                        ),
                      )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final task in tasks)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Checkbox(
                                    value: task.status == 'completed',
                                    onChanged:
                                        identity == null ||
                                            active ||
                                            _operations.busy
                                        ? null
                                        : (value) => _setTaskCompletion(
                                            id,
                                            task.id,
                                            identity,
                                            value == true,
                                          ),
                                  ),
                                  Expanded(child: SelectableText(task.task)),
                                  IconButton(
                                    tooltip: 'Edit task',
                                    onPressed:
                                        identity == null ||
                                            active ||
                                            _operations.busy
                                        ? null
                                        : () => unawaited(
                                            editMeetingTask(
                                              task,
                                              identity,
                                            ).catchError(
                                              _operations.reportAsyncError,
                                            ),
                                          ),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                ],
                              ),
                              Text(
                                '${task.owner ?? 'Unassigned'}${task.due == null ? '' : ' · Due: ${task.due}'} · ${task.status}',
                              ),
                              if (task.stale)
                                const Text(
                                  'Not found in the latest extraction — retained for review',
                                ),
                              if (task.manual)
                                const Text('Your edits are preserved'),
                              _taskEvidence(task),
                            ],
                          ),
                        ),
                      ),
                    if (versions.length > 1)
                      ExpansionTile(
                        title: const Text('Previous versions'),
                        children: [
                          for (final version in versions.skip(1))
                            ListTile(
                              title: GeneratedContent(
                                version.body,
                                openLink: _host.environment.openUri,
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
        ),
      ],
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

  Widget _taskEvidence(MeetingTask task) => ExpansionTile(
    title: const Text('Supporting evidence'),
    children: [
      for (final quote in task.evidence)
        ListTile(title: SelectableText(quote.quote), subtitle: Text(quote.id)),
    ],
  );

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
        builder: (dialog) => AlertDialog(
          title: const Text('Edit task'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: text,
                  decoration: const InputDecoration(labelText: 'Task'),
                ),
                TextField(
                  controller: owner,
                  decoration: const InputDecoration(
                    labelText: 'Owner (optional)',
                  ),
                ),
                TextField(
                  controller: due,
                  decoration: const InputDecoration(
                    labelText: 'Due date or expression (optional)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Save'),
            ),
          ],
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
        builder: (dialog, update) => AlertDialog(
          title: const Text('Select local documents'),
          content: SizedBox(
            width: 500,
            height: 350,
            child: all.isEmpty
                ? const Text(
                    'Import documents first. This operation uses local sources and does not fetch attachments.',
                  )
                : ListView(
                    children: [
                      for (final source in all)
                        CheckboxListTile(
                          value: selected.contains(source.id),
                          title: Text(source.title),
                          onChanged: (value) => update(() {
                            if (value == true) {
                              selected.add(source.id);
                            } else {
                              selected.remove(source.id);
                            }
                          }),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selected.isEmpty || selected.length > 100
                  ? null
                  : () => Navigator.pop(dialog, selected.toList()),
              child: const Text('Use selected documents'),
            ),
          ],
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
    final artifact = versions.firstOrNull;
    final manifest = artifact?.manifest ?? const {};
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Meeting preparation',
                  style: TextStyle(fontSize: 20),
                ),
              ),
              IconButton(
                tooltip: 'Prepare from local documents',
                onPressed: identity == null || active || _operations.busy
                    ? null
                    : () => _runMeetingAction(
                        id,
                        identity,
                        (current) => generatePreparation(id, identity, current),
                      ),
                icon: const Icon(Icons.auto_awesome),
              ),
              if (artifact != null)
                IconButton(
                  tooltip: 'Copy preparation',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: artifact.body)),
                  icon: const Icon(Icons.copy_outlined),
                ),
            ],
          ),
        ),
        _workflowProgress(id, 'preparation'),
        Expanded(
          child: artifact == null && preview.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(
                      'Select imported attachments or documents to prepare for this meeting.',
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (manifest['reduction_clipped'] == true)
                        const Text(
                          'This brief used shortened excerpts. Review the source documents for full context.',
                        ),
                      if (manifest['degraded'] == true)
                        const Text(
                          'Some documents could not be summarized. See unavailable documents below.',
                        ),
                      GeneratedContent(
                        active && preview.isNotEmpty ? preview : artifact!.body,
                        openLink: _host.environment.openUri,
                      ),
                      if (artifact != null)
                        TextButton(
                          onPressed: active
                              ? null
                              : () => unawaited(
                                  editArtifact(
                                    artifact,
                                  ).catchError(_operations.reportAsyncError),
                                ),
                          child: const Text('Edit preparation'),
                        ),
                      if (versions.length > 1)
                        ExpansionTile(
                          title: const Text('Previous versions'),
                          children: [
                            for (final old in versions.skip(1))
                              GeneratedContent(
                                old.body,
                                openLink: _host.environment.openUri,
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
