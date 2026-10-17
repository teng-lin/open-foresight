import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String operationError(Object error) =>
    error is StateError ? error.message.toString() : error.toString();

/// Keep the editor and its draft mounted until the write actually succeeds.
class RecoverableDialog extends StatefulWidget {
  const RecoverableDialog({
    super.key,
    required this.title,
    required this.saveLabel,
    required this.editor,
    required this.save,
    this.validate,
    this.width = 650,
    this.textAction = false,
  });
  final String title, saveLabel;
  final Widget Function(bool saving, VoidCallback submit) editor;
  final Future<void> Function() save;
  final String? Function()? validate;
  final double width;
  final bool textAction;

  @override
  State<RecoverableDialog> createState() => _RecoverableDialogState();
}

class _RecoverableDialogState extends State<RecoverableDialog> {
  bool saving = false, finished = false;
  String error = '';

  Future<void> submit() async {
    if (saving || finished) return;
    final invalid = widget.validate?.call();
    if (invalid != null) {
      setState(() => error = invalid);
      return;
    }
    setState(() {
      saving = true;
      error = '';
    });
    try {
      await widget.save();
      finished = true;
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) setState(() => error = operationError(failure));
    } finally {
      if (mounted && !finished) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.enter, meta: true): submit,
      const SingleActivator(LogicalKeyboardKey.enter, control: true): submit,
    },
    child: PopScope(
      canPop: !saving,
      child: AlertDialog(
        scrollable: true,
        title: Text(widget.title),
        content: SizedBox(
          width: widget.width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              widget.editor(saving, submit),
              if (saving) const LinearProgressIndicator(),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          if (widget.textAction)
            TextButton(
              onPressed: saving ? null : submit,
              child: Text(widget.saveLabel),
            )
          else
            FilledButton(
              onPressed: saving ? null : submit,
              child: Text(widget.saveLabel),
            ),
        ],
      ),
    ),
  );
}
