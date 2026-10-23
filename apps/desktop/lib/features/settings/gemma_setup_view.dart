import '../../desktop_environment.dart';
import 'model_setup_surface.dart';
import 'dart:io';
import 'dart:async';
import 'model_terms_dialog.dart';
import 'read_model.dart';
import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';

class GemmaSetupDialog extends StatefulWidget {
  final DesktopEnvironment environment;
  final VoidCallback? onDone;
  bool get embedded => onDone != null;
  final StoreReader store;
  final bool Function()? ownerCurrent;
  final ModelPreferenceWriter savePreference;
  final GemmaDownload Function()? createDownload;
  final LocalModelFinder findLocalModel;
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
    this.environment = const DesktopEnvironment(),
    this.onDone,
    required this.store,
    this.ownerCurrent,
    required this.savePreference,
    this.createDownload,
    this.findLocalModel = localModelFile,
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
  bool get active => mounted && (widget.ownerCurrent?.call() ?? true);
  late GemmaModel selected;
  late bool embeddingReady;
  ModelRegistration? registeredGeneration, registeredEmbedding;
  final downloaded = <GemmaModel, bool>{};
  final verifiedFiles = <GemmaModel, File>{};
  bool checkingCache = true;

  bool isCurrent(GemmaModel model) {
    final registration = registeredGeneration;
    if (registration == null ||
        registration.digest != model.digest ||
        registration.backend != 'litert_lm')
      return false;
    final file = File(registration.path);
    final runner = File(registration.runtime);
    return verifiedFiles[model]?.path == file.path &&
        file.existsSync() &&
        file.lengthSync() == model.bytes &&
        runner.existsSync() &&
        (runner.statSync().mode & 0x49) != 0;
  }

  bool get done =>
      embeddingReady && (!widget.needsGeneration || isCurrent(selected));

  Directory get embeddingDirectory =>
      Directory('${widget.directory.parent.path}/embeddinggemma2');
  File? get localEmbedding => verifiedFiles[embeddingGemmaModel];
  bool get embeddingCached => localEmbedding != null;
  File? localGeneration(GemmaModel model) => verifiedFiles[model];
  bool enoughMemory(GemmaModel model) =>
      widget.memoryGb > 0 && widget.memoryGb >= model.minimumMemoryGb;

  Future<void> checkLocalModels() async {
    for (final model in [
      ...gemmaModels,
      if (!embeddingReady) embeddingGemmaModel,
    ]) {
      final file = await widget.findLocalModel(
        model,
        model == embeddingGemmaModel ? embeddingDirectory : widget.directory,
        registration: cacheRegistration(
          model == embeddingGemmaModel
              ? registeredEmbedding
              : registeredGeneration,
        ),
      );
      if (!active) return;
      if (file != null) verifiedFiles[model] = file;
    }
    if (!active) return;
    setState(() {
      for (final model in gemmaModels)
        downloaded[model] = verifiedFiles.containsKey(model);
      selected =
          gemmaModels
              .where((model) => model.digest == registeredGeneration?.digest)
              .firstOrNull ??
          gemmaModels
              .where(
                (model) => downloaded[model] == true && enoughMemory(model),
              )
              .firstOrNull ??
          selected;
      checkingCache = false;
    });
  }

  GemmaDownload? download;

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
    for (final model in gemmaModels) {
      downloaded[model] = false;
    }
    selected = widget.memoryGb == 0
        ? gemmaModels.last
        : gemmaModels
                  .where((model) => widget.memoryGb >= model.minimumMemoryGb)
                  .firstOrNull ??
              gemmaModels.last;
    unawaited(prepareModels());
  }

  Future<void> prepareModels() async {
    final epoch = widget.store.workspaceEpoch;
    try {
      final values = await Future.wait([
        readSetupModel(widget.store, 'generation'),
        readSetupModel(widget.store, 'embedding'),
      ]);
      if (!active || widget.store.workspaceEpoch != epoch) return;
      registeredGeneration = values[0];
      registeredEmbedding = values[1];
      embeddingReady =
          !widget.needsEmbedding ||
          !preparedNeedsModel(registeredEmbedding, 'embedding');
      selected =
          gemmaModels
              .where((model) => model.digest == registeredGeneration?.digest)
              .firstOrNull ??
          selected;
      await checkLocalModels();
    } catch (failure) {
      if (active)
        setState(() {
          error = failure.toString();
          checkingCache = false;
        });
    }
  }

  void finish() {
    if (widget.onDone != null) {
      widget.onDone!();
    } else {
      Navigator.pop(context);
    }
  }

  void cancel() {
    cancelled = true;
    download?.cancel();
    preflight?.kill();
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

  Future<void> install() async {
    if (working || checkingCache) return;
    if (done) {
      finish();
      return;
    }
    final installGeneration = widget.needsGeneration && !isCurrent(selected);
    final model = selected;
    if (installGeneration && !enoughMemory(model)) return;
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
    try {
      for (final termsModel in [
        if (!embeddingReady && !embeddingCached) embeddingGemmaModel,
        if (installGeneration && localGeneration(model) == null) model,
      ]) {
        if (!await confirmModelTerms(
          context,
          widget.store,
          termsModel,
          savePreference: widget.savePreference,
          openUri: widget.environment.openUri,
        ))
          return;
        if (!active || cancelled) return;
      }
      download = widget.createDownload?.call() ?? GemmaDownload();
      final process = preflight = await widget.environment.start(
        widget.runner,
        ['--check'],
      );
      final out = process.stdout.listen((_) {}),
          err = process.stderr.listen((_) {});
      try {
        if (!active || cancelled) {
          process.kill();
          return;
        }
        final code = await process.exitCode.timeout(
          const Duration(seconds: 30),
        );
        if (!active || cancelled) return;
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
      if (!active || cancelled) return;
      if (!embeddingReady) {
        setState(() => status = 'Checking downloaded EmbeddingGemma 2...');
        final embedding = await download!.download(
          embeddingGemmaModel,
          embeddingDirectory,
          existingFile: localEmbedding,
          progress: reportProgress,
          phase: (phase) => reportPhase(embeddingGemmaModel, phase),
        );
        if (!active || cancelled) return;
        setState(() => status = 'Loading EmbeddingGemma 2...');
        await widget.installEmbedding!(embedding, () => active && !cancelled);
        if (!active || cancelled) return;
        embeddingReady = true;
      }
      if (!installGeneration) {
        if (active) finish();
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
      if (!active || cancelled) return;
      setState(() {
        downloaded[model] = true;
        verifiedFiles[model] = asset;
        status = 'Loading ${model.name} and preparing GPU cache...';
      });
      final install = widget.installGeneration;
      if (install == null)
        throw StateError('Model installation service is unavailable');
      final ready = await install(
        asset.path,
        widget.runner,
        () => active && !cancelled,
      );
      if (!active || cancelled) {
        ready.close();
        return;
      }
      widget.installed(ready, model);
      if (active) finish();
    } on ModelDownloadCancelled {
      if (active) setState(() => status = 'Download cancelled.');
    } catch (failure) {
      if (active && !cancelled)
        setState(() {
          error = failure is StateError
              ? failure.message.toString()
              : 'Unable to download or load this model. Retry or use local model setup.';
        });
    } finally {
      clock.stop();
      if (active) setState(() => working = false);
    }
  }

  void reportPhase(GemmaModel model, ModelDownloadPhase phase) {
    if (!active || cancelled) return;
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
    if (!active || cancelled) return;
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
    child: ModelSetupSurface(
      embedded: widget.embedded,
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
                                          checkingCache ||
                                          !enoughMemory(model)
                                      ? null
                                      : () {
                                          setState(() => selected = model);
                                          // This task catches failures and publishes them in the view state.
                                          // ignore: discarded_futures
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
                              !working && !checkingCache && enoughMemory(model),
                        ),
                    ],
                  ),
                ),
              if (widget.needsGeneration && widget.memoryGb <= 0)
                const Text(
                  'Device memory could not be determined. Automatic generation model setup is unavailable.',
                ),
              if (checkingCache) const Text('Verifying saved models…'),
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
                    : widget.embedded
                    ? 'Choose your transcription model in the next step.'
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
        if (!widget.embedded)
          TextButton(
            onPressed: working
                ? null
                : () {
                    cancel();
                    finish();
                    widget.localSetup();
                  },
            child: const Text('Use local models'),
          ),
        if (!widget.embedded)
          TextButton(
            onPressed: () {
              cancel();
              finish();
            },
            child: const Text('Cancel'),
          ),
        FilledButton(
          onPressed:
              working ||
                  checkingCache ||
                  (!done &&
                      (widget.runner.isEmpty ||
                          (widget.needsGeneration &&
                              !isCurrent(selected) &&
                              !enoughMemory(selected))))
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
