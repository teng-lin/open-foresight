import 'model_catalog.dart';

// Official whisper.cpp artifact metadata, verified against the Hugging Face
// repository API on 2026-10-15. All choices are multilingual (not .en models).
final speechModels = [
  for (final filename in [
    'ggml-tiny.bin',
    'ggml-base.bin',
    'ggml-small.bin',
    'ggml-medium.bin',
    'ggml-large-v3-turbo.bin',
  ])
    modelFromPin(filename),
];
