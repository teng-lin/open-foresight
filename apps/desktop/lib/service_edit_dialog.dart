import 'package:flutter/material.dart';
import 'failure_text.dart';

/// Retains the edit until the service accepts it and offers an inline retry.
class ServiceEditDialog extends StatefulWidget {
  const ServiceEditDialog({
    super.key,
    required this.title,
    required this.controller,
    required this.saveLabel,
    required this.onSave,
    this.onChanged,
    this.height = 300,
  });
  final String title, saveLabel;
  final TextEditingController controller;
  final Future<void> Function() onSave;
  final ValueChanged<String>? onChanged;
  final double height;

  @override
  State<ServiceEditDialog> createState() => _ServiceEditDialogState();
}

class _ServiceEditDialogState extends State<ServiceEditDialog> {
  String? error;
  bool saving = false;

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.onSave();
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted)
        setState(() => error = 'Unable to save: ${failureText(failure)}');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 650,
      height: widget.height,
      child: Column(
        children: [
          Expanded(
            child: TextField(
              controller: widget.controller,
              onChanged: widget.onChanged,
              maxLines: null,
              expands: true,
              enabled: !saving,
            ),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: saving ? null : save,
        child: Text(saving ? 'Saving…' : widget.saveLabel),
      ),
    ],
  );
}
