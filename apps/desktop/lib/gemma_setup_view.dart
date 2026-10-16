import 'dart:io';
import 'package:flutter/material.dart';
import 'gemma_download.dart';
import 'model_setup.dart';
import 'native.dart';
import 'store.dart';

class GemmaSetupDialog extends StatefulWidget {
  final Store store;
  final Directory directory;
  final String library, runner;
  final int memoryGb;
  final void Function(NativeRuntime, GemmaModel) installed;
  final VoidCallback localSetup;
  const GemmaSetupDialog({
    super.key,
    required this.store,
    required this.directory,
    required this.library,
    required this.runner,
    required this.memoryGb,
    required this.installed,
    required this.localSetup,
  });
  @override
  State<GemmaSetupDialog> createState() => _GemmaSetupDialogState();
}

class _GemmaSetupDialogState extends State<GemmaSetupDialog> {
  late GemmaModel selected;
  GemmaDownload? download;
  NativeRuntime? candidate;
  Process? preflight;
  bool working = false, cancelled = false;
  String status = '', error = '';
  int received = 0, total = 0;
  final clock = Stopwatch();
  int lastUpdate = 0;
  @override
  void initState() {
    super.initState();
    final digest = widget.store
        .rows("SELECT digest FROM models WHERE kind='generation'")
        .firstOrNull?['digest'];
    selected =
        gemmaModels.where((model) => model.digest == digest).firstOrNull ??
        (widget.memoryGb == 0
            ? gemmaModels.last
            : gemmaModels
                      .where(
                        (model) => widget.memoryGb >= model.minimumMemoryGb,
                      )
                      .firstOrNull ??
                  gemmaModels.last);
  }

  void cancel() {
    cancelled = true;
    download?.cancel();
    candidate?.close();
    preflight?.kill();
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

  Future<void> install() async {
    if (working) return;
    final model = selected;
    setState(() {
      working = true;
      cancelled = false;
      error = '';
      received = 0;
      total = 0;
      status = 'Checking local Gemma runtime...';
    });
    clock
      ..reset()
      ..start();
    lastUpdate = 0;
    download = GemmaDownload();
    try {
      final process = preflight = await Process.start(widget.runner, [
        '--check',
      ]);
      final out = process.stdout.listen((_) {}),
          err = process.stderr.listen((_) {});
      try {
        if (!mounted || cancelled) {
          process.kill();
          return;
        }
        final code = await process.exitCode.timeout(
          const Duration(seconds: 30),
        );
        if (!mounted || cancelled) return;
        if (code != 0)
          throw StateError(
            'The local Gemma runtime is not ready. Use local model setup to install or configure it.',
          );
      } finally {
        process.kill();
        await out.cancel();
        await err.cancel();
        preflight = null;
      }
      if (!mounted || cancelled) return;
      setState(() => status = 'Downloading ${model.name}...');
      final asset = await download!.download(
        model,
        widget.directory,
        progress: (count, size) {
          if (!mounted || cancelled) return;
          if (count != size && clock.elapsedMilliseconds - lastUpdate < 100)
            return;
          lastUpdate = clock.elapsedMilliseconds;
          setState(() {
            received = count;
            total = size;
            if (count == size) status = 'Verifying ${model.name}...';
          });
        },
      );
      if (!mounted || cancelled) return;
      setState(() => status = 'Loading ${model.name}...');
      final ready = await configureGeneration(
        widget.store,
        widget.library,
        asset.path,
        widget.runner,
        backend: 'litert_lm',
        current: () => mounted && !cancelled,
        onCandidate: (value) => candidate = value,
      );
      candidate = null; // ownership is transferred only after a complete load.
      if (!mounted || cancelled) {
        ready.close();
        return;
      }
      widget.installed(ready, model);
      if (mounted) Navigator.pop(context);
    } on ModelDownloadCancelled {
      if (mounted) setState(() => status = 'Download cancelled.');
    } catch (failure) {
      if (mounted && !cancelled)
        setState(() {
          error = failure is StateError
              ? failure.message.toString()
              : 'Unable to download or load this model. Retry or use local model setup.';
        });
    } finally {
      clock.stop();
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (_, _) => cancel(),
    child: AlertDialog(
      title: const Text('Local Inference Model'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Foresight uses models run locally on your device. Choose the Gemma model that best fits your device. This is a one-time download, and you can switch models later in Settings.',
              ),
              const SizedBox(height: 20),
              RadioGroup<GemmaModel>(
                groupValue: selected,
                onChanged: (value) => setState(() => selected = value!),
                child: Column(
                  children: [
                    for (final model in gemmaModels)
                      RadioListTile<GemmaModel>(
                        title: Text(model.name),
                        subtitle: Text(
                          '${model.minimumMemoryGb} GB memory · ${(model.bytes / 1e9).toStringAsFixed(2)} GB download',
                        ),
                        value: model,
                        enabled:
                            !working &&
                            (widget.memoryGb == 0 ||
                                widget.memoryGb >= model.minimumMemoryGb),
                      ),
                  ],
                ),
              ),
              if (widget.memoryGb > 0)
                Text('Device memory: ${widget.memoryGb} GB'),
              const SizedBox(height: 16),
              const Text(
                'Please keep Foresight open until the download completes.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Speech and source search models require separate setup.',
              ),
              if (widget.runner.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Set up the local Gemma runner before downloading.',
                  ),
                ),
              if (working) ...[
                const SizedBox(height: 16),
                Text(status),
                LinearProgressIndicator(
                  value: total == 0 || received == total
                      ? null
                      : received / total,
                ),
                if (total > 0)
                  Text(
                    '${(received / 1e9).toStringAsFixed(2)} / ${(total / 1e9).toStringAsFixed(2)} GB',
                  ),
              ],
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: working
              ? null
              : () {
                  cancel();
                  Navigator.pop(context);
                  widget.localSetup();
                },
          child: const Text('Use local models'),
        ),
        TextButton(
          onPressed: () {
            cancel();
            Navigator.pop(context);
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              working ||
                  widget.runner.isEmpty ||
                  (widget.memoryGb != 0 &&
                      widget.memoryGb < selected.minimumMemoryGb)
              ? null
              : install,
          child: const Text('Continue'),
        ),
      ],
    ),
  );
}
