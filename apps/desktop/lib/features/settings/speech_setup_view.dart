import '../../desktop_environment.dart';
import 'model_setup_surface.dart';
import 'dart:io';
import 'dart:async';
import 'model_terms_dialog.dart';
import 'read_model.dart';
import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';

class SpeechSetupDialog extends StatefulWidget {
  final DesktopEnvironment environment;
  final VoidCallback? onDone;
  bool get embedded => onDone != null;
  final StoreReader store;
  final bool Function()? ownerCurrent;
  final ModelPreferenceWriter savePreference;
  final ModelDownloader Function()? createDownload;
  final LocalModelFinder findLocalModel;
  final Future<void> Function(File, String, String, bool Function())?
  installSpeech;
  final Directory directory;
  final String runner;
  final VoidCallback installed;
  const SpeechSetupDialog({
    super.key,
    this.environment = const DesktopEnvironment(),
    this.onDone,
    required this.store,
    this.ownerCurrent,
    required this.savePreference,
    this.createDownload,
    this.findLocalModel = localModelFile,
    this.installSpeech,
    required this.directory,
    required this.runner,
    required this.installed,
  });
  @override
  State<SpeechSetupDialog> createState() => _SpeechSetupDialogState();
}

class _SpeechSetupDialogState extends State<SpeechSetupDialog> {
  bool get active => mounted && (widget.ownerCurrent?.call() ?? true);
  late GemmaModel selected;
  String? currentDigest, currentPath, currentRunner;
  ModelRegistration? registration;
  bool working = false, cancelled = false;
  String status = '', error = '';
  double? progress;
  ModelDownloader? download;
  final verifiedFiles = <GemmaModel, File>{};
  bool checkingCache = true;
  @override
  void initState() {
    super.initState();
    selected = speechModels[3];
    unawaited(prepareModel());
  }

  Future<void> prepareModel() async {
    final epoch = widget.store.workspaceEpoch;
    try {
      registration = await readSetupModel(widget.store, 'speech');
      if (!active || widget.store.workspaceEpoch != epoch) return;
      currentDigest = registration?.digest;
      currentPath = registration?.path;
      currentRunner = registration?.runtime;
      selected =
          speechModels
              .where((model) => model.digest == currentDigest)
              .firstOrNull ??
          selected;
      await checkLocalModels();
    } catch (failure) {
      if (active)
        setState(() {
          error = modelSetupFailureMessage(failure);
          checkingCache = false;
        });
    }
  }

  bool isCurrent(GemmaModel model) =>
      verifiedFiles[model]?.path == currentPath &&
      model.digest == currentDigest &&
      currentPath != null &&
      File(currentPath!).existsSync() &&
      File(currentPath!).lengthSync() == model.bytes &&
      currentRunner != null &&
      File(currentRunner!).existsSync() &&
      (File(currentRunner!).statSync().mode & 0x49) != 0;
  File? localFile(GemmaModel model) => verifiedFiles[model];
  Future<void> checkLocalModels() async {
    for (final model in speechModels) {
      final file = await widget.findLocalModel(
        model,
        widget.directory,
        registration: cacheRegistration(registration),
      );
      if (!active) return;
      if (file != null) verifiedFiles[model] = file;
    }
    if (active) setState(() => checkingCache = false);
  }

  bool cached(GemmaModel model) => localFile(model) != null;

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
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

  Future<void> install() async {
    if (working || checkingCache) return;
    if (isCurrent(selected)) {
      finish();
      return;
    }
    setState(() {
      working = true;
      cancelled = false;
      error = '';
      progress = null;
    });
    try {
      download = widget.createDownload?.call();
      if (download == null)
        throw StateError('Model download service is unavailable');
      final model = selected;
      if (!cached(model) &&
          !await confirmModelTerms(
            context,
            widget.store,
            model,
            savePreference: widget.savePreference,
            openUri: widget.environment.openUri,
          ))
        return;
      if (!active || cancelled) return;
      final asset = await download!.download(
        model,
        widget.directory,
        existingFile: localFile(model),
        phase: (phase) {
          if (active && !cancelled)
            setState(
              () => status = switch (phase) {
                ModelDownloadPhase.checkingCache =>
                  'Checking downloaded model...',
                ModelDownloadPhase.verifyingCache =>
                  'Verifying downloaded model...',
                ModelDownloadPhase.downloading =>
                  'Downloading ${model.name}...',
                ModelDownloadPhase.verifyingDownload => 'Verifying download...',
              },
            );
        },
        progress: (received, total) {
          if (active && !cancelled) setState(() => progress = received / total);
        },
      );
      if (!active || cancelled) return;
      setState(() {
        status = 'Loading ${model.name} on the configured device...';
        progress = null;
      });
      final install = widget.installSpeech;
      if (install == null)
        throw StateError('Speech installation service is unavailable');
      await install(
        asset,
        widget.runner,
        model.digest,
        () => active && !cancelled,
      );
      if (!active || cancelled) return;
      widget.installed();
      if (active) finish();
    } on ModelDownloadCancelled {
      // Closing this dialog leaves the previous registration intact.
    } catch (failure) {
      if (active && !cancelled)
        setState(() => error = modelSetupFailureMessage(failure));
    } finally {
      if (active) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => ModelSetupSurface(
    embedded: widget.embedded,
    title: const Text('Transcription Model'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'These multilingual models support Chinese and English. Language is detected automatically and speech is transcribed in its original language. Small is a compact choice; Large v3 Turbo offers stronger multilingual transcription. Accuracy with rapid language switching varies.',
            ),
            const SizedBox(height: 16),
            RadioGroup<GemmaModel>(
              groupValue: selected,
              onChanged: (value) {
                if (!working && value != null) setState(() => selected = value);
              },
              child: Column(
                children: [
                  for (final model in speechModels)
                    RadioListTile<GemmaModel>(
                      value: model,
                      enabled: !working && !checkingCache,
                      title: Text(model.name),
                      subtitle: Text(
                        '${(model.bytes / 1000000).round()} MB · ${isCurrent(model)
                            ? 'Current model'
                            : cached(model)
                            ? 'Downloaded'
                            : 'Download required'}',
                      ),
                      secondary: cached(model)
                          ? null
                          : TextButton(
                              onPressed: working || checkingCache
                                  ? null
                                  : () {
                                      setState(() => selected = model);
                                      // This task catches failures and publishes them in the view state.
                                      // ignore: discarded_futures
                                      install();
                                    },
                              child: const Text('Click to download'),
                            ),
                    ),
                ],
              ),
            ),
            if (checkingCache) const Text('Verifying saved models…'),
            if (working) ...[
              const SizedBox(height: 12),
              Text(status),
              LinearProgressIndicator(value: progress),
            ],
            if (error.isNotEmpty)
              Text(error, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            if (!widget.embedded)
              SelectableText(
                'Models: ${widget.directory.path}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (!widget.embedded)
        TextButton(
          onPressed: () {
            cancel();
            finish();
          },
          child: const Text('Cancel'),
        ),
      FilledButton(
        onPressed: working || checkingCache || widget.runner.isEmpty
            ? null
            : install,
        child: Text(
          isCurrent(selected)
              ? 'Done'
              : cached(selected)
              ? 'Use model'
              : 'Continue',
        ),
      ),
    ],
  );
}
