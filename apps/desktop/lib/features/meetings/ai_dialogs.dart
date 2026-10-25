import 'package:flutter/material.dart';

class MeetingTaskEditor extends StatelessWidget {
  const MeetingTaskEditor({
    super.key,
    required this.text,
    required this.owner,
    required this.due,
    required this.onCancel,
    required this.onSave,
  });
  final TextEditingController text, owner, due;
  final VoidCallback onCancel, onSave;
  @override
  Widget build(BuildContext context) => AlertDialog(
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
            decoration: const InputDecoration(labelText: 'Owner (optional)'),
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
      TextButton(onPressed: () => onCancel(), child: const Text('Cancel')),
      FilledButton(onPressed: () => onSave(), child: const Text('Save')),
    ],
  );
}

class MeetingSourceChoice {
  const MeetingSourceChoice(this.id, this.title);
  final String id, title;
}

class MeetingSourceSelection extends StatelessWidget {
  MeetingSourceSelection({
    super.key,
    required List<MeetingSourceChoice> sources,
    required Set<String> selected,
    required this.onSelected,
    required this.onCancel,
    required this.onConfirm,
  }) : sources = List.unmodifiable(sources),
       selected = Set.unmodifiable(selected);
  final List<MeetingSourceChoice> sources;
  final Set<String> selected;
  final void Function(String, bool) onSelected;
  final VoidCallback onCancel, onConfirm;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Select local documents'),
    content: SizedBox(
      width: 500,
      height: 350,
      child: sources.isEmpty
          ? const Text(
              'Import documents first. This operation uses local sources and does not fetch attachments.',
            )
          : ListView(
              children: [
                for (final source in sources)
                  CheckboxListTile(
                    value: selected.contains(source.id),
                    title: Text(source.title),
                    onChanged: (value) => onSelected(source.id, value == true),
                  ),
              ],
            ),
    ),
    actions: [
      TextButton(onPressed: () => onCancel(), child: const Text('Cancel')),
      FilledButton(
        onPressed: selected.isEmpty || selected.length > 100
            ? null
            : () => onConfirm(),
        child: const Text('Use selected documents'),
      ),
    ],
  );
}
