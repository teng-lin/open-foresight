import 'package:flutter/material.dart';
import 'recoverable_dialog.dart';

class ImportTask {
  const ImportTask(this.label, this.run);
  final String label;
  final Future<void> Function() run;
}

class ImportFailure {
  const ImportFailure(this.task, this.error);
  final ImportTask task;
  final String error;
}

Future<List<ImportFailure>> attemptImports(List<ImportTask> tasks) async {
  final failures = <ImportFailure>[];
  for (final task in tasks) {
    try {
      await task.run();
    } catch (error) {
      failures.add(ImportFailure(task, operationError(error)));
    }
  }
  return failures;
}

/// Retry only unsuccessful tasks; completed imports are never resubmitted.
class ImportBatchDialog extends StatefulWidget {
  const ImportBatchDialog({
    super.key,
    required this.failures,
    required this.total,
    this.beforeRetry,
  });
  final List<ImportFailure> failures;
  final int total;
  final Future<void> Function()? beforeRetry;
  @override
  State<ImportBatchDialog> createState() => _ImportBatchDialogState();
}

class _ImportBatchDialogState extends State<ImportBatchDialog> {
  late List<ImportFailure> failures = widget.failures;
  bool working = false;
  String error = '';
  Future<void> retry() async {
    if (working) return;
    setState(() {
      working = true;
      error = '';
    });
    try {
      await widget.beforeRetry?.call();
      final next = await attemptImports(failures.map((f) => f.task).toList());
      if (mounted) setState(() => failures = next);
    } catch (failure) {
      if (mounted) setState(() => error = operationError(failure));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !working,
    child: AlertDialog(
      scrollable: true,
      title: const Text('Import results'),
      content: SizedBox(
        width: 550,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.total - failures.length} of ${widget.total} imports completed.',
            ),
            if (working) const LinearProgressIndicator(),
            if (error.isNotEmpty) Text(error),
            for (final failure in failures)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('${failure.task.label}: ${failure.error}'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: working ? null : () => Navigator.pop(context),
          child: Text(failures.isEmpty ? 'Done' : 'Close'),
        ),
        if (failures.isNotEmpty)
          FilledButton(
            onPressed: working ? null : retry,
            child: const Text('Retry failed imports'),
          ),
      ],
    ),
  );
}
