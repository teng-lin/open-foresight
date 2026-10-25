import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';

/// Note values are immutable; editor handles remain owned and retired by the
/// controller, which also owns every save/retry/review operation.
class NoteEditor extends StatelessWidget {
  NoteEditor({
    super.key,
    required List<NoteSummary> notes,
    required this.noteTitle,
    required this.noteBody,
    required this.canSave,
    required this.status,
    this.problem,
    required this.onNew,
    required this.onSave,
    required this.onOpen,
  }) : notes = List.unmodifiable(notes);
  final List<NoteSummary> notes;
  final TextEditingController noteTitle, noteBody;
  final bool canSave;
  final String? problem;
  final Widget status;
  final VoidCallback onNew, onSave;
  final ValueChanged<NoteSummary> onOpen;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 260,
        child: Column(
          children: [
            if (problem != null) Text(problem!),
            FilledButton(onPressed: onNew, child: const Text('New note')),
            Expanded(
              child: ListView(
                children: notes
                    .map(
                      (n) => ListTile(
                        title: Text(n.title),
                        subtitle: Text('Revision ${n.revision}'),
                        onTap: () => onOpen(n),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
      const VerticalDivider(),
      Expanded(
        child: Column(
          children: [
            status,
            TextField(
              controller: noteTitle,
              readOnly: !canSave,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            Expanded(
              child: TextField(
                controller: noteBody,
                readOnly: !canSave,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  labelText: 'Your editable note',
                  alignLabelWithHint: true,
                ),
              ),
            ),
            FilledButton(
              onPressed: canSave ? onSave : null,
              child: const Text('Save note'),
            ),
          ],
        ),
      ),
    ],
  );
}

class SavedNoteReviewDialog extends StatelessWidget {
  const SavedNoteReviewDialog({
    super.key,
    required this.title,
    required this.body,
  });
  final String title, body;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Saved note'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title),
            const SizedBox(height: 12),
            SelectableText(body),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Use saved note'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Keep my draft'),
      ),
    ],
  );
}

/// A saved-note read problem; the owner validates every retry/review callback.
class NoteLoadStatus extends StatelessWidget {
  const NoteLoadStatus({
    super.key,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });
  final String message, actionLabel;
  final VoidCallback onAction;
  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(message),
    trailing: TextButton(onPressed: onAction, child: Text(actionLabel)),
  );
}
