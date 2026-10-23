import 'platform_services.dart';
import 'dart:io';
import 'dart:typed_data';
import 'gemma_download.dart';
import 'store.dart';
import 'runtime_execution_policy.dart';

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

/// Validates that the selected runner can actually load and decode the model.
/// Uses generated silence, never the microphone. The caller owns cancellation
/// of the probe subprocess and only registers a still-current candidate.
Future<void> configureSpeech(
  Store store,
  File asset,
  String runner,
  String digest, {
  required bool Function() current,
  void Function(Process)? onProcess,
}) async {
  requireInstalledRuntime(runner);
  final executable = File(runner);
  if (!executable.existsSync() || (executable.statSync().mode & 0x49) == 0) {
    throw StateError('The whisper.cpp runner is missing or not executable.');
  }
  final scratch = await Directory.systemTemp.createTemp(
    'foresight-speech-probe-',
  );
  Process? process;
  try {
    // One second of mono PCM16 silence at 16 kHz.
    final wav = ByteData(44 + 32000);
    void label(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        wav.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    label(0, 'RIFF');
    wav.setUint32(4, 32036, Endian.little);
    label(8, 'WAVEfmt ');
    wav.setUint32(16, 16, Endian.little);
    wav.setUint16(20, 1, Endian.little);
    wav.setUint16(22, 1, Endian.little);
    wav.setUint32(24, 16000, Endian.little);
    wav.setUint32(28, 32000, Endian.little);
    wav.setUint16(32, 2, Endian.little);
    wav.setUint16(34, 16, Endian.little);
    label(36, 'data');
    wav.setUint32(40, 32000, Endian.little);
    final sample = File('${scratch.path}/silence.wav');
    await sample.writeAsBytes(wav.buffer.asUint8List());
    if (!current()) throw const ModelDownloadCancelled();
    final arguments = [
      '-m',
      asset.path,
      '-f',
      sample.path,
      '-l',
      'auto',
      '-nt',
      '-np',
      '-t',
      '4',
    ];
    if (runtimeConfiguration['FORESIGHT_WHISPER_BACKEND'] == 'cpu') {
      arguments.add('-ng');
    } else if (runtimeConfiguration['FORESIGHT_WHISPER_DEVICE']
        case final String device when device.isNotEmpty) {
      arguments.addAll(['-dev', device]);
    }
    process = await Process.start(
      runner,
      arguments,
      environment: runtimeConfiguration.environment,
    );
    onProcess?.call(process);
    final stdout = process.stdout.drain<void>();
    final stderr = process.stderr.drain<void>();
    final code = await process.exitCode.timeout(const Duration(minutes: 3));
    await Future.wait([stdout, stderr]);
    if (!current()) throw const ModelDownloadCancelled();
    if (code != 0) {
      throw StateError(
        'Whisper could not load this model on the configured device. Your previous model is unchanged.',
      );
    }
    await store.register(
      'speech',
      asset.path,
      runner,
      expectedDigest: digest,
      current: current,
    );
  } finally {
    process?.kill();
    await scratch.delete(recursive: true);
  }
}
