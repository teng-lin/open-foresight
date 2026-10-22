part of 'main.dart';

extension _MeetingAiViews on _MeetingsController {
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
    final identity = FeatureRequestIdentity.capture(d);
    final key = automatic ? 'proactiveScope.$id' : 'answerScope.meeting:$id';
    final scope = d.store.preference(key, automatic ? 'meeting' : 'workspace');
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
              onChanged: shell.busy
                  ? null
                  : (value) => _runMeetingAction(id, identity, (current) async {
                      if (value == 'selected') {
                        final ids = await selectMeetingSources(
                          id,
                          'answerSourcesSelection',
                        );
                        if (ids == null) return;
                        if (!current()) return;
                        await d.commandCurrent(Operation.preferencesSet, {
                          'key': 'answerSources.meeting:$id',
                          'value': jsonEncode(ids),
                          'workspace_epoch': identity.workspaceEpoch,
                        }, current);
                        if (!current()) return;
                        await d.commandCurrent(Operation.preferencesSet, {
                          'key': 'answerSourcesSelection.$id',
                          'value': jsonEncode(ids),
                          'workspace_epoch': identity.workspaceEpoch,
                        }, current);
                      }
                      if (!current()) return;
                      await d.commandCurrent(Operation.preferencesSet, {
                        'key': key,
                        'value': value!,
                        'workspace_epoch': identity.workspaceEpoch,
                      }, current);
                    }),
            ),
          ),
        ],
      ),
    );
  }

  Map? _workflow(int id, String kind) =>
      (d.capture['meeting_workflows'] as Map?)?['$id:$kind'] as Map?;

  Widget _workflowProgress(int id, String kind) {
    final state = _workflow(id, kind);
    if (state?['active'] != true) {
      return state?['error'] is String &&
              (state!['error'] as String).isNotEmpty &&
              state['cancelled'] != true
          ? Padding(
              padding: const EdgeInsets.all(12),
              child: Text(state['error'] as String),
            )
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
                child: Text(switch (state?['phase']) {
                  'extracting' =>
                    'Extracting commitments ${state?['completed']}/${state?['total']}…',
                  'documents' =>
                    'Preparing documents ${state?['completed']}/${state?['total']}…',
                  'synthesizing' => 'Writing the preparation brief…',
                  'reducing' => 'Combining document topics…',
                  _ => 'Planning meeting generation…',
                }),
              ),
            ),
            TextButton(
              onPressed: () => unawaited(
                d
                    .command(Operation.meetingsCancelGeneration, {
                      'id': id,
                      'kind': kind,
                    })
                    .catchError(shell.reportAsyncError),
              ),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget meetingActionsPanel(int id) {
    final identity = FeatureRequestIdentity.capture(d);
    final tasks = readRows(d.store.meetingTasks(id));
    final versions = readRows(d.store.meetingArtifacts(id, 'actions'));
    final active = _workflow(id, 'actions')?['active'] == true;
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
                onPressed: active || shell.busy
                    ? null
                    : () => _runMeetingAction(id, identity, (current) async {
                        await d.commandCurrent(Operation.meetingsGenerate, {
                          'id': id,
                          'kind': 'actions',
                          'workspace_epoch': identity.workspaceEpoch,
                        }, current);
                      }),
                icon: const Icon(Icons.auto_awesome),
              ),
              if (versions.isNotEmpty)
                IconButton(
                  tooltip: 'Copy Action items',
                  onPressed: () => Clipboard.setData(
                    ClipboardData(
                      text:
                          (versions.first['edited'] ??
                                  versions.first['generated'])
                              as String,
                    ),
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
                          (versions.first['edited'] ??
                                  versions.first['generated'])
                              as String,
                          openLink: widget.environment.openUri,
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
                                    value: task['status'] == 'completed',
                                    onChanged: active || shell.busy
                                        ? null
                                        : (value) =>
                                              _runMeetingAction(id, identity, (
                                                current,
                                              ) async {
                                                await d.commandCurrent(
                                                  Operation.meetingsEditTask,
                                                  {
                                                    'id': task['id'],
                                                    'status': value == true
                                                        ? 'completed'
                                                        : 'open',
                                                    'workspace_epoch':
                                                        identity.workspaceEpoch,
                                                  },
                                                  current,
                                                );
                                              }),
                                  ),
                                  Expanded(
                                    child: SelectableText(
                                      task['task'] as String,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Edit task',
                                    onPressed: active || shell.busy
                                        ? null
                                        : () => unawaited(
                                            editMeetingTask(
                                              task,
                                              identity,
                                            ).catchError(
                                              shell.reportAsyncError,
                                            ),
                                          ),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                ],
                              ),
                              Text(
                                '${task['owner'] ?? 'Unassigned'}${task['due'] == null ? '' : ' · Due: ${task['due']}'} · ${task['status']}',
                              ),
                              if (task['stale'] == 1)
                                const Text(
                                  'Not found in the latest extraction — retained for review',
                                ),
                              if (task['manual'] == 1)
                                const Text('Your edits are preserved'),
                              ExpansionTile(
                                title: const Text('Supporting evidence'),
                                children: [
                                  for (final quote
                                      in jsonDecode(task['evidence'] as String)
                                          as List)
                                    ListTile(
                                      title: SelectableText(
                                        quote['quote'] as String,
                                      ),
                                      subtitle: Text(quote['id'] as String),
                                    ),
                                ],
                              ),
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
                                (version['edited'] ?? version['generated'])
                                    as String,
                                openLink: widget.environment.openUri,
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

  Future<void> editMeetingTask(
    Map<String, Object?> task,
    FeatureRequestIdentity identity,
  ) async {
    final selectedMeeting = meetingId;
    if (task['meeting_id'] != selectedMeeting) return;
    bool current() =>
        meetingId == selectedMeeting && identity.isCurrent(d, alive: mounted);
    if (!current()) return;
    final text = TextEditingController(text: task['task'] as String),
        owner = TextEditingController(text: task['owner'] as String? ?? ''),
        due = TextEditingController(text: task['due'] as String? ?? '');
    try {
      final save = await shell.showInputDialog<bool>(
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
        await d.commandCurrent(Operation.meetingsEditTask, {
          'id': task['id'],
          'task': text.text,
          'owner': owner.text.trim().isEmpty ? null : owner.text.trim(),
          'due': due.text.trim().isEmpty ? null : due.text.trim(),
          'workspace_epoch': identity.workspaceEpoch,
        }, current);
    } catch (_) {
      if (current()) rethrow;
    } finally {
      text.dispose();
      owner.dispose();
      due.dispose();
    }
  }

  Future<List<String>?> selectMeetingSources(int id, String preference) async {
    final all = readRows(d.store.sourceSummaries)
        .where(
          (source) =>
              !(source['id'] as String).startsWith('meeting-preparation-'),
        )
        .toList();
    final saved = d.store.preference('$preference.$id', '[]');
    final selected = (jsonDecode(saved) as List).cast<String>().toSet()
      ..retainAll(all.map((source) => source['id'] as String));
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
                          value: selected.contains(source['id']),
                          title: Text(source['title'] as String),
                          onChanged: (value) => update(() {
                            if (value == true) {
                              selected.add(source['id'] as String);
                            } else {
                              selected.remove(source['id']);
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
    await d.commandCurrent(Operation.preferencesSet, {
      'key': 'preparationSources.$id',
      'value': jsonEncode(sources),
      'workspace_epoch': identity.workspaceEpoch,
    }, current);
    if (!current()) return;
    await d.commandCurrent(Operation.meetingsPrepare, {
      'id': id,
      'source_ids': sources,
      'workspace_epoch': identity.workspaceEpoch,
    }, current);
  }

  Widget meetingPreparationPanel(int id) {
    final identity = FeatureRequestIdentity.capture(d);
    final versions = readRows(d.store.meetingArtifacts(id, 'preparation'));
    final active = _workflow(id, 'preparation')?['active'] == true;
    final preview = _workflow(id, 'preparation')?['preview'] as String? ?? '';
    final artifact = versions.firstOrNull;
    final manifest = artifact?['manifest'] == null
        ? const {}
        : jsonDecode(artifact!['manifest'] as String) as Map;
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
                onPressed: active || shell.busy
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
                  onPressed: () => Clipboard.setData(
                    ClipboardData(
                      text:
                          (artifact['edited'] ?? artifact['generated'])
                              as String,
                    ),
                  ),
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
                        active && preview.isNotEmpty
                            ? preview
                            : (artifact!['edited'] ?? artifact['generated'])
                                  as String,
                        openLink: widget.environment.openUri,
                      ),
                      if (artifact != null)
                        TextButton(
                          onPressed: active
                              ? null
                              : () => unawaited(
                                  editArtifact(
                                    artifact,
                                  ).catchError(shell.reportAsyncError),
                                ),
                          child: const Text('Edit preparation'),
                        ),
                      if (versions.length > 1)
                        ExpansionTile(
                          title: const Text('Previous versions'),
                          children: [
                            for (final old in versions.skip(1))
                              GeneratedContent(
                                (old['edited'] ?? old['generated']) as String,
                                openLink: widget.environment.openUri,
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
