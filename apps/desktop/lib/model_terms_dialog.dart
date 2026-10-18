import 'package:flutter/material.dart';
import 'gemma_download.dart';
import 'package:foresight_core/foresight_core.dart' show openPlatformUri;
import 'store.dart';

/// Acknowledgment is scoped to the exact publisher revision, independently for
/// generation, embedding and speech. It happens before any model HTTP request.
Future<bool> confirmModelTerms(
  BuildContext context,
  Store store,
  GemmaModel model,
) async {
  final key = 'modelTerms.${model.repository}.${model.revision}';
  if (store.preference(key) == 'accepted') return true;
  final card = Uri.https(
    'huggingface.co',
    '/${model.repository}/blob/${model.revision}/README.md',
  );
  final whisper = model.repository == 'ggerganov/whisper.cpp';
  final license = whisper
      ? Uri.parse('https://github.com/openai/whisper/blob/main/LICENSE')
      : card;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${model.name} terms'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                whisper
                    ? 'Whisper model weights are provided by OpenAI under the MIT License. Keep the copyright and permission notice when redistributing the model. The model is provided without warranty.'
                    : '${model.name} is provided by its model publisher. Review the license and usage terms on the pinned model card before downloading. Any use or redistribution must follow those terms.',
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => openPlatformUri(license),
                child: Text(
                  whisper ? 'Read MIT License' : 'Read publisher model terms',
                ),
              ),
              SelectableText(license.toString()),
              if (whisper) ...[
                TextButton(
                  onPressed: () => openPlatformUri(card),
                  child: const Text('Model source and conversion'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Accept and download'),
        ),
      ],
    ),
  );
  if (accepted != true) return false;
  store.setPreference(key, 'accepted');
  return true;
}

/// The distribution must supply genuine publisher terms; no inferred license is
/// displayed for the authenticated dedicated question asset.
Future<bool> confirmQueryModelTerms(
  BuildContext context,
  Uri terms,
  String revision,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Automatic question model terms'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Review the distribution provider’s model license and usage terms before downloading this revision.',
                ),
                TextButton(
                  onPressed: () => openPlatformUri(terms),
                  child: const Text('Read model terms'),
                ),
                SelectableText(terms.toString()),
                SelectableText('Model revision: $revision'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Accept and download'),
          ),
        ],
      ),
    ) ??
    false;
