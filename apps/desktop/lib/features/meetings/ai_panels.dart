import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart'
    show MeetingArtifact, MeetingRunPresentation, MeetingTask;
import '../../generated_content.dart';

class MeetingAnswerScope extends StatelessWidget {
  const MeetingAnswerScope({super.key, required this.scope, this.onChanged});
  final String scope;
  final ValueChanged<String?>? onChanged;
  @override
  Widget build(BuildContext context) => Padding(
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
            onChanged: onChanged,
          ),
        ),
      ],
    ),
  );
}

class MeetingWorkflowProgress extends StatelessWidget {
  const MeetingWorkflowProgress({
    super.key,
    this.state,
    required this.onCancel,
  });
  final MeetingRunPresentation? state;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) {
    final state = this.state;
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
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }
}

class MeetingActionsPanel extends StatelessWidget {
  MeetingActionsPanel({
    super.key,
    required List<MeetingTask> tasks,
    required List<MeetingArtifact> versions,
    required this.progress,
    required this.openLink,
    this.onGenerate,
    required this.onCopy,
    this.onComplete,
    this.onEdit,
  }) : tasks = List.unmodifiable(tasks),
       versions = List.unmodifiable(versions);
  final List<MeetingTask> tasks;
  final List<MeetingArtifact> versions;
  final Widget progress;
  final Future<void> Function(Uri) openLink;
  final VoidCallback? onGenerate;
  final ValueChanged<String> onCopy;
  final void Function(MeetingTask, bool)? onComplete;
  final ValueChanged<MeetingTask>? onEdit;
  @override
  Widget build(BuildContext context) => Column(
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
              onPressed: onGenerate,
              icon: const Icon(Icons.auto_awesome),
            ),
            if (versions.isNotEmpty)
              IconButton(
                tooltip: 'Copy Action items',
                onPressed: () => onCopy(versions.first.body),
                icon: const Icon(Icons.copy_outlined),
              ),
          ],
        ),
      ),
      progress,
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
                        openLink: openLink,
                      ),
                    )
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final task in tasks)
                    MeetingTaskCard(
                      task: task,
                      onComplete: onComplete == null
                          ? null
                          : (value) => onComplete!(task, value),
                      onEdit: onEdit == null ? null : () => onEdit!(task),
                    ),
                  if (versions.length > 1)
                    ExpansionTile(
                      title: const Text('Previous versions'),
                      children: [
                        for (final version in versions.skip(1))
                          ListTile(
                            title: GeneratedContent(
                              version.body,
                              openLink: openLink,
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

class MeetingTaskCard extends StatelessWidget {
  const MeetingTaskCard({
    super.key,
    required this.task,
    this.onComplete,
    this.onEdit,
  });
  final MeetingTask task;
  final ValueChanged<bool>? onComplete;
  final VoidCallback? onEdit;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: task.status == 'completed',
                onChanged: onComplete == null
                    ? null
                    : (value) => onComplete!(value == true),
              ),
              Expanded(child: SelectableText(task.task)),
              IconButton(
                tooltip: 'Edit task',
                onPressed: onEdit,
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
          if (task.manual) const Text('Your edits are preserved'),
          _taskEvidence(task),
        ],
      ),
    ),
  );
  Widget _taskEvidence(MeetingTask task) => ExpansionTile(
    title: const Text('Supporting evidence'),
    children: [
      for (final quote in task.evidence)
        ListTile(title: SelectableText(quote.quote), subtitle: Text(quote.id)),
    ],
  );
}

class MeetingPreparationPanel extends StatelessWidget {
  MeetingPreparationPanel({
    super.key,
    required List<MeetingArtifact> versions,
    required this.active,
    required this.preview,
    required this.progress,
    required this.openLink,
    this.onGenerate,
    required this.onCopy,
    required this.onEdit,
  }) : versions = List.unmodifiable(versions);
  final List<MeetingArtifact> versions;
  final bool active;
  final String preview;
  final Widget progress;
  final Future<void> Function(Uri) openLink;
  final VoidCallback? onGenerate;
  final ValueChanged<String> onCopy;
  final ValueChanged<MeetingArtifact> onEdit;
  @override
  Widget build(BuildContext context) {
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
                onPressed: onGenerate,
                icon: const Icon(Icons.auto_awesome),
              ),
              if (artifact != null)
                IconButton(
                  tooltip: 'Copy preparation',
                  onPressed: () => onCopy(artifact.body),
                  icon: const Icon(Icons.copy_outlined),
                ),
            ],
          ),
        ),
        progress,
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
                        openLink: openLink,
                      ),
                      if (artifact != null)
                        TextButton(
                          onPressed: active ? null : () => onEdit(artifact),
                          child: const Text('Edit preparation'),
                        ),
                      if (versions.length > 1)
                        ExpansionTile(
                          title: const Text('Previous versions'),
                          children: [
                            for (final old in versions.skip(1))
                              GeneratedContent(old.body, openLink: openLink),
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
