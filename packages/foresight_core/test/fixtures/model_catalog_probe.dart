import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/src/gemma_download.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    final file = await GemmaDownload().download(
      gemmaModels.first,
      Directory(args.single),
    );
    print(jsonEncode({'downloaded': file.lengthSync()}));
    return;
  }
  final generation = gemmaModels.first, embedding = embeddingGemmaModel;
  print(
    jsonEncode({
      'generation': generation.name,
      'generation_bytes': generation.bytes,
      'embedding': embedding.name,
      'embedding_bytes': embedding.bytes,
      'source': compiledFixtureModelSource(generation)?.toString(),
      'loopback_allowed': isCompiledFixtureModelSource(
        Uri.parse('http://127.0.0.1:34567/generation'),
      ),
      'escape_allowed': isCompiledFixtureModelSource(
        Uri.parse('https://example.com/generation'),
      ),
    }),
  );
}
