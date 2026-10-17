import 'package:foresight_core/remote.dart' show GenerationStatus;
import 'dart:io';
import 'package:flutter/material.dart';
import 'gemma_download.dart';
import 'model_setup.dart';
import 'native.dart';
import 'store.dart';

class GemmaSetupDialog extends StatefulWidget {
  final Store store;
  final GemmaDownload Function()? createDownload;
  final bool firstRun, needsEmbedding, needsGeneration;
  final Future<void> Function(File, bool Function())? installEmbedding;
  final Directory directory;
  final String library, runner;
  final int memoryGb;
  final void Function(GenerationStatus, GemmaModel) installed;
  final VoidCallback localSetup;
  final Future<GenerationStatus> Function(String, String, bool Function())?
  installGeneration;
  const GemmaSetupDialog({
    super.key,
    required this.store,
    this.createDownload,
    this.installGeneration,
    this.firstRun = false,
    this.needsEmbedding = false,
    this.needsGeneration = true,
    this.installEmbedding,
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
  late bool embeddingReady;
  Map<String, Object?>? registeredGeneration;
  final downloaded = <GemmaModel, bool>{};

  bool isCurrent(GemmaModel model) {
    final registration = registeredGeneration;
    if (registration == null ||
        registration['digest'] != model.digest ||
        registration['backend'] != 'litert_lm')
      return false;
    final file = File(registration['path'] as String);
    final runner = File(registration['runtime'] as String);
    return file.existsSync() &&
        file.lengthSync() == model.bytes &&
        runner.existsSync() &&
        (runner.statSync().mode & 0x49) != 0;
  }

  bool get done =>
      embeddingReady && (!widget.needsGeneration || isCurrent(selected));

  Directory get embeddingDirectory =>
      Directory('${widget.directory.parent.path}/embeddinggemma2');
  File? get localEmbedding => localModelFile(
    embeddingGemmaModel,
    embeddingDirectory,
    registration: widget.store.model('embedding'),
  );
  bool get embeddingCached => localEmbedding != null;
  File? localGeneration(GemmaModel model) => localModelFile(
    model,
    widget.directory,
    registration: registeredGeneration,
  );

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
    embeddingReady = !widget.needsEmbedding;
    registeredGeneration = widget.store.model('generation');
    final digest = registeredGeneration?['digest'];
    for (final model in gemmaModels) {
      downloaded[model] = localGeneration(model) != null;
    }
    selected =
        gemmaModels.where((model) => model.digest == digest).firstOrNull ??
        gemmaModels
            .where(
              (model) =>
                  downloaded[model] == true &&
                  (widget.memoryGb == 0 ||
                      widget.memoryGb >= model.minimumMemoryGb),
            )
            .firstOrNull ??
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
    if (done) {
      Navigator.pop(context);
      return;
    }
    final installGeneration = widget.needsGeneration && !isCurrent(selected);
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
    download = widget.createDownload?.call() ?? GemmaDownload();
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
      if (!embeddingReady) {
        setState(() => status = 'Checking downloaded EmbeddingGemma 2...');
        final embedding = await download!.download(
          embeddingGemmaModel,
          embeddingDirectory,
          existingFile: localEmbedding,
          progress: reportProgress,
          phase: (phase) => reportPhase(embeddingGemmaModel, phase),
        );
        if (!mounted || cancelled) return;
        setState(() => status = 'Loading EmbeddingGemma 2...');
        await widget.installEmbedding!(embedding, () => mounted && !cancelled);
        if (!mounted || cancelled) return;
        embeddingReady = true;
      }
      if (!installGeneration) {
        if (mounted) Navigator.pop(context);
        return;
      }
      setState(() {
        status = 'Checking downloaded ${model.name}...';
        received = 0;
        total = 0;
      });
      final asset = await download!.download(
        model,
        widget.directory,
        existingFile: localGeneration(model),
        progress: reportProgress,
        phase: (phase) => reportPhase(model, phase),
      );
      if (!mounted || cancelled) return;
      setState(() {
        downloaded[model] = true;
        status = 'Loading ${model.name} and preparing GPU cache...';
      });
      final ready = widget.installGeneration != null
          ? await widget.installGeneration!(
              asset.path,
              widget.runner,
              () => mounted && !cancelled,
            )
          : await configureGeneration(
              widget.store,
              widget.library,
              asset.path,
              widget.runner,
              backend: 'litert_lm',
              current: () => mounted && !cancelled,
              onCandidate: (value) => candidate = value,
              onRegister: () {
                if (mounted && !cancelled)
                  setState(
                    () => status = 'Saving ${model.name} registration...',
                  );
              },
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

  void reportPhase(GemmaModel model, ModelDownloadPhase phase) {
    if (!mounted || cancelled) return;
    setState(
      () => status = switch (phase) {
        ModelDownloadPhase.checkingCache =>
          'Checking downloaded ${model.name}...',
        ModelDownloadPhase.verifyingCache =>
          'Verifying downloaded ${model.name} — no download needed...',
        ModelDownloadPhase.downloading => 'Downloading ${model.name}...',
        ModelDownloadPhase.verifyingDownload =>
          'Verifying ${model.name} download...',
      },
    );
  }

  void reportProgress(int count, int size) {
    if (!mounted || cancelled) return;
    if (count != size && clock.elapsedMilliseconds - lastUpdate < 100) return;
    lastUpdate = clock.elapsedMilliseconds;
    setState(() {
      received = count;
      total = size;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (_, _) => cancel(),
    child: AlertDialog(
      title: Text(
        !widget.needsGeneration
            ? embeddingCached
                  ? 'Use EmbeddingGemma 2'
                  : 'Download EmbeddingGemma 2'
            : widget.needsEmbedding
            ? 'Set up local models'
            : widget.firstRun
            ? 'Choose your Gemma model'
            : 'Local Inference Model',
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.needsGeneration
                    ? 'Choose the Gemma model that best fits your device. Models run locally, and you can switch them later in Settings.'
                    : embeddingCached
                    ? 'EmbeddingGemma 2 is already on this computer. Use it for local source search.'
                    : 'Local source search needs an embedding model. Download it now or use an existing local model.',
              ),
              if (!embeddingReady) ...[
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.manage_search),
                  title: const Text('EmbeddingGemma 2'),
                  subtitle: Text(
                    embeddingCached
                        ? 'Downloaded · Ready to use for local source search'
                        : '485 MB download · Required for local source search',
                  ),
                ),
                Text(
                  embeddingCached
                      ? 'The existing embedding model will be verified and reused.'
                      : widget.needsGeneration
                      ? 'Setup will reuse downloaded models and download any missing models.'
                      : 'Nothing is downloaded until you choose Download EmbeddingGemma 2.',
                ),
              ],
              const SizedBox(height: 20),
              if (widget.needsGeneration)
                RadioGroup<GemmaModel>(
                  groupValue: selected,
                  onChanged: (value) => setState(() => selected = value!),
                  child: Column(
                    children: [
                      for (final model in gemmaModels)
                        RadioListTile<GemmaModel>(
                          title: Text(model.name),
                          subtitle: Text(
                            '${model.minimumMemoryGb} GB memory · ${(model.bytes / 1e9).toStringAsFixed(2)} GB${isCurrent(model)
                                ? ' · Current model'
                                : downloaded[model] == true
                                ? ' · Downloaded'
                                : ' download'}',
                          ),
                          secondary:
                              isCurrent(model) || downloaded[model] == true
                              ? null
                              : TextButton(
                                  onPressed:
                                      working ||
                                          (widget.memoryGb != 0 &&
                                              widget.memoryGb <
                                                  model.minimumMemoryGb)
                                      ? null
                                      : () {
                                          setState(() => selected = model);
                                          if (embeddingReady) install();
                                        },
                                  child: Text(
                                    embeddingReady
                                        ? 'Click to download'
                                        : 'Select',
                                  ),
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
              Text(
                done
                    ? 'This model is already configured. No download is needed.'
                    : (!embeddingReady && !embeddingCached) ||
                          (widget.needsGeneration &&
                              !isCurrent(selected) &&
                              downloaded[selected] != true)
                    ? 'Keep Open Foresight open until setup completes.'
                    : 'The downloaded model will be verified and loaded. No download is needed.',
              ),
              const SizedBox(height: 8),
              Text(
                !embeddingReady
                    ? 'You can cancel setup without changing existing model registrations.'
                    : 'Speech models are configured separately in Settings.',
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
                  (!done &&
                      (widget.runner.isEmpty ||
                          (widget.needsGeneration &&
                              !isCurrent(selected) &&
                              widget.memoryGb != 0 &&
                              widget.memoryGb < selected.minimumMemoryGb)))
              ? null
              : install,
          child: Text(
            done
                ? 'Done'
                : error.isNotEmpty
                ? 'Retry'
                : !embeddingReady
                ? widget.needsGeneration
                      ? (embeddingCached &&
                                (isCurrent(selected) ||
                                    downloaded[selected] == true)
                            ? 'Use models'
                            : 'Download models')
                      : embeddingCached
                      ? 'Use EmbeddingGemma 2'
                      : 'Download EmbeddingGemma 2'
                : downloaded[selected] == true
                ? 'Use model'
                : 'Continue',
          ),
        ),
      ],
    ),
  );
}
