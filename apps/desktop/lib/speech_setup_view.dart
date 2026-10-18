import 'dart:io';
import 'dart:async';
import 'model_terms_dialog.dart';
import 'package:flutter/material.dart';
import 'gemma_download.dart';
import 'speech_models.dart';
import 'store.dart';

class SpeechSetupDialog extends StatefulWidget {
  final Store store;
  final LocalModelFinder findLocalModel;
  final Future<void> Function(File, String, String, bool Function())?
  installSpeech;
  final Directory directory;
  final String runner;
  final VoidCallback installed;
  const SpeechSetupDialog({
    super.key,
    required this.store,
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
  late GemmaModel selected;
  String? currentDigest, currentPath, currentRunner;
  Map<String, Object?>? registration;
  bool working = false, cancelled = false;
  String status = '', error = '';
  double? progress;
  GemmaDownload? download;
  final verifiedFiles = <GemmaModel, File>{};
  bool checkingCache = true;
  Process? probe;
  @override
  void initState() {
    super.initState();
    currentDigest =
        widget.store.registeredSpeech().firstOrNull?['digest'] as String?;
    registration = widget.store.model('speech');
    currentPath = registration?['path'] as String?;
    currentRunner = registration?['runtime'] as String?;
    selected =
        speechModels.where((m) => m.digest == currentDigest).firstOrNull ??
        speechModels.where(cached).firstOrNull ??
        speechModels[2];
    unawaited(checkLocalModels());
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
        registration: registration,
      );
      if (!mounted) return;
      if (file != null) verifiedFiles[model] = file;
    }
    if (mounted) setState(() => checkingCache = false);
  }

  bool cached(GemmaModel model) => localFile(model) != null;

  void cancel() {
    cancelled = true;
    download?.cancel();
    probe?.kill();
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

  Future<void> install() async {
    if (working || checkingCache) return;
    if (isCurrent(selected)) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      working = true;
      cancelled = false;
      error = '';
      progress = null;
    });
    download = GemmaDownload();
    try {
      final model = selected;
      if (!cached(model) &&
          !await confirmModelTerms(context, widget.store, model))
        return;
      if (!mounted || cancelled) return;
      final asset = await download!.download(
        model,
        widget.directory,
        existingFile: localFile(model),
        phase: (phase) {
          if (mounted && !cancelled)
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
          if (mounted && !cancelled)
            setState(() => progress = received / total);
        },
      );
      if (!mounted || cancelled) return;
      setState(() {
        status = 'Loading ${model.name} on the configured device...';
        progress = null;
      });
      if (widget.installSpeech != null) {
        await widget.installSpeech!(
          asset,
          widget.runner,
          model.digest,
          () => mounted && !cancelled,
        );
      } else {
        await configureSpeech(
          widget.store,
          asset,
          widget.runner,
          model.digest,
          current: () => mounted && !cancelled,
          onProcess: (process) {
            probe = process;
            if (cancelled) process.kill();
          },
        );
        if (!mounted || cancelled) return;
      }
      widget.installed();
      if (mounted) Navigator.pop(context);
    } on ModelDownloadCancelled {
      // Closing this dialog leaves the previous registration intact.
    } catch (failure) {
      if (mounted && !cancelled) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
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
            SelectableText(
              'Models: ${widget.directory.path}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          cancel();
          Navigator.pop(context);
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
