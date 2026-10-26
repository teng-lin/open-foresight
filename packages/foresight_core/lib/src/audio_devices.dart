import 'native_lifetime.dart';
import 'audio_device_process.dart';
import 'audio_device.dart';
export 'audio_device.dart';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'platform_services.dart';
import 'dart:convert';
import 'dart:io';

final _deviceProcess = AudioDeviceProcessRunner();

Future<List<AudioDevice>> audioDevices({
  bool? macOS,
  Future<ProcessResult> Function(String executable, List<String> arguments)?
  runProcess,
  RuntimeConfiguration? configuration,
}) async {
  final run = runProcess ?? _deviceProcess.run;
  if (macOS ?? Platform.isMacOS) {
    final helper = runtimeSnapshot(configuration)['FORESIGHT_AUDIO_DEVICES'];
    if (helper == null) {
      throw StateError('The bundled Mac audio device adapter is unavailable.');
    }
    final result = await run(helper, [
      '--list-devices',
    ]).timeout(const Duration(seconds: 10));
    if (result.exitCode != 0) {
      throw StateError('Mac audio discovery failed: ${result.stderr}');
    }
    final devices = (jsonDecode(result.stdout as String) as List).map((entry) {
      final item = entry as Map;
      return AudioDevice(
        item['id'] as String,
        item['label'] as String,
        item['playback'] as bool,
      );
    }).toList();
    devices.sort((a, b) => a.label.compareTo(b.label));
    return devices;
  }

  final result = await run('pw-dump', []).timeout(const Duration(seconds: 10));
  if (result.exitCode != 0) {
    throw StateError('PipeWire audio devices are unavailable.');
  }
  final devices = <AudioDevice>[];
  for (final item in jsonDecode(result.stdout as String) as List) {
    final info = (item as Map)['info'];
    if (info is! Map) continue;
    final properties = info['props'];
    if (properties is! Map) continue;
    final media = properties['media.class'];
    if (media != 'Audio/Source' && media != 'Audio/Sink') continue;
    final name = properties['node.name'];
    if (name is! String) continue;
    devices.add(
      AudioDevice(
        name,
        (properties['node.description'] ?? properties['node.nick'] ?? name)
            .toString(),
        media == 'Audio/Sink',
      ),
    );
  }
  devices.sort((a, b) => a.label.compareTo(b.label));
  return devices;
}

/// Querying capabilities never asks for protected resources or starts capture.
Map<String, dynamic> audioCapabilities({RuntimeConfiguration? configuration}) {
  final lib = NativeLibrary(
    DynamicLibrary.open(runtimeSnapshot(configuration).nativeLibrary),
  ).library;
  final result = lib
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'fs_audio_capabilities',
      )();
  if (result == nullptr) throw StateError('Audio capability query failed');
  try {
    return Map<String, dynamic>.from(jsonDecode(result.toDartString()) as Map);
  } finally {
    lib.lookupFunction<
      Void Function(Pointer<Utf8>),
      void Function(Pointer<Utf8>)
    >('fs_string_free')(result);
  }
}

/// Explicit permission setup only. Run the blocking TCC request off the service
/// event loop so other clients and active model/recording work stay responsive.
Future<Map<String, dynamic>> requestMicrophonePermission({
  RuntimeConfiguration? configuration,
}) async {
  final config = runtimeSnapshot(configuration);
  final capabilities = audioCapabilities(configuration: config);
  if (Platform.isMacOS && capabilities['microphone_purpose_present'] != true) {
    throw StateError(
      'The application service bundle is missing its microphone purpose string. Launch the installed Open Foresight application service and reinstall if necessary.',
    );
  }
  // Only the resolved library path crosses into the request isolate.
  final path = config.nativeLibrary;
  final granted = await Isolate.run(() {
    final lib = NativeLibrary(DynamicLibrary.open(path)).library;
    return lib.lookupFunction<Int32 Function(), int Function()>(
          'fs_audio_request_microphone',
        )() ==
        0;
  });
  return {'granted': granted, ...audioCapabilities(configuration: config)};
}

/// Explicitly exercise the service's system-audio tap consent path. CoreAudio
/// cannot verify authorization publicly: completed requests may still be silent.
/// Preserve native unknown/pending/denied results instead of claiming a grant.
Future<Map<String, dynamic>> requestSystemAudioPermission({
  RuntimeConfiguration? configuration,
}) async {
  final config = runtimeSnapshot(configuration);
  final capabilities = audioCapabilities(configuration: config);
  if (Platform.isMacOS &&
      capabilities['system_audio_purpose_present'] != true) {
    throw StateError(
      'The application service bundle is missing its system audio purpose string. Launch the installed Open Foresight application service and reinstall if necessary.',
    );
  }
  final path = config.nativeLibrary;
  return await Isolate.run(() {
    final lib = NativeLibrary(DynamicLibrary.open(path)).library;
    final result = lib
        .lookupFunction<
          Pointer<Utf8> Function(Int32),
          Pointer<Utf8> Function(int)
        >('fs_audio_request_system')(10000);
    if (result == nullptr) {
      throw StateError('System audio permission request failed');
    }
    try {
      return Map<String, dynamic>.from(
        jsonDecode(result.toDartString()) as Map,
      );
    } finally {
      lib.lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('fs_string_free')(result);
    }
  });
}
