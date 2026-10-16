import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'dart:convert';
import 'dart:io';

/// The same immutable resource map is used by Finder, MCP and detached workers.
/// Paths in runtime.json are relative to Contents/Resources, never the cwd.
const _scalarRuntimeKeys = {
  'FORESIGHT_LITERT_BACKEND',
  'FORESIGHT_WHISPER_BACKEND',
  'FORESIGHT_WHISPER_DEVICE',
  'FORESIGHT_MICROPHONE_TARGET',
  'FORESIGHT_PLAYBACK_TARGET',
  'FORESIGHT_TEST_DELAY_MS',
  'FORESIGHT_CRASH_AT',
};

class RuntimeConfiguration {
  final Map<String, String> environment;
  RuntimeConfiguration(this.environment);
  factory RuntimeConfiguration.resolve({
    Map<String, String>? environment,
    String? executable,
  }) {
    final values = Map<String, String>.from(
      environment ?? Platform.environment,
    );
    final path = executable ?? Platform.resolvedExecutable;
    final marker = path.lastIndexOf('.app/Contents/');
    final resources =
        values['FORESIGHT_RESOURCES'] ??
        (marker < 0
            ? null
            : '${path.substring(0, marker + 4)}/Contents/Resources');
    if (resources != null) {
      final file = File('$resources/runtime.json');
      if (file.existsSync()) {
        final entries =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        for (final entry in entries.entries) {
          if ((!entry.key.startsWith('FORESIGHT_') &&
                  entry.key != 'PYTHONPYCACHEPREFIX') ||
              entry.value is! String) {
            throw FormatException(
              'Invalid runtime configuration key: ${entry.key}',
            );
          }
          final relative = entry.value as String;
          values.putIfAbsent(
            entry.key,
            () =>
                _scalarRuntimeKeys.contains(entry.key) ||
                    relative.startsWith('/')
                ? relative
                : '$resources/$relative',
          );
        }
      }
      values['FORESIGHT_RESOURCES'] = resources;
    }
    return RuntimeConfiguration(values);
  }
  String? operator [](String key) => environment[key];
  String get nativeLibrary =>
      this['FORESIGHT_NATIVE'] ??
      (Platform.isMacOS
          ? 'libforesight_native.dylib'
          : 'libforesight_native.so');
}

final runtimeConfiguration = RuntimeConfiguration.resolve();

/// Refuse symlinks and foreign/public directories before using local RPC state.
void privateDirectory(String path) {
  final dir = Directory(path);
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw StateError('Private directory must not be a symbolic link: $path');
  }
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
    if (Process.runSync('/bin/chmod', ['700', path]).exitCode != 0) {
      throw StateError('Cannot protect $path');
    }
  }
  final owner = Process.runSync(
    '/usr/bin/stat',
    Platform.isMacOS ? ['-f', '%u', path] : ['-Lc', '%u', path],
  );
  final user = Process.runSync('/usr/bin/id', ['-u']);
  if (owner.exitCode != 0 ||
      user.exitCode != 0 ||
      owner.stdout.toString().trim() != user.stdout.toString().trim() ||
      (dir.statSync().mode & 0x3f) != 0) {
    throw StateError('Requires private user-owned directory: $path');
  }
}

int systemMemoryGb() {
  if (Platform.isMacOS) {
    final result = Process.runSync('/usr/sbin/sysctl', ['-n', 'hw.memsize']);
    if (result.exitCode != 0) return 0;
    return ((int.tryParse(result.stdout.toString().trim()) ?? 0) / 1073741824)
        .round();
  }
  if (Platform.isLinux) {
    final text = File('/proc/meminfo').readAsStringSync();
    final kb = int.tryParse(
      RegExp(r'MemTotal:\s+(\d+)').firstMatch(text)?.group(1) ?? '',
    );
    return kb == null ? 0 : (kb / 1048576).round();
  }
  return 0;
}

Future<void> openPlatformUri(Uri uri) async {
  final result = await Process.run(
    Platform.isMacOS ? '/usr/bin/open' : 'xdg-open',
    [uri.toString()],
  );
  if (result.exitCode != 0)
    throw StateError('Could not open $uri: ${result.stderr}');
}

Future<void> platformNotification(String title, String message) async {
  final helper = runtimeConfiguration['FORESIGHT_NOTIFICATIONS'];
  final result = Platform.isMacOS
      ? helper == null
            ? throw StateError(
                'The bundled notification adapter is unavailable. Reinstall Open Foresight.',
              )
            : await Process.run(helper, [
                '--title',
                title,
                '--message',
                message,
              ])
      : await Process.run('notify-send', [title, message]);
  if (result.exitCode != 0)
    throw StateError(
      'Notification delivery failed. Check notification permission in system settings: ${result.stderr}',
    );
}

const _nativeEnvironmentKeys = {
  'FORESIGHT_LITERT_BACKEND',
  'FORESIGHT_WHISPER_BACKEND',
  'FORESIGHT_WHISPER_DEVICE',
  'FORESIGHT_HELPER',
  'FORESIGHT_LITERT_CACHE',
  'FORESIGHT_WHISPER_RUNTIME',
  'PYTHONPYCACHEPREFIX',
};
bool _nativeEnvironmentConfigured = false;

/// Configure C/C++ getenv consumers once, before service-owned workers start.
/// Dart's resource map does not otherwise modify the process environment.
void configureNativeEnvironment() {
  if (_nativeEnvironmentConfigured) return;
  final values = runtimeConfiguration.environment.entries
      .where(
        (entry) =>
            _nativeEnvironmentKeys.contains(entry.key) &&
            entry.value.isNotEmpty,
      )
      .toList();
  if (values.isEmpty) {
    _nativeEnvironmentConfigured = true;
    return;
  }
  final lib = DynamicLibrary.open(runtimeConfiguration.nativeLibrary);
  final configure = lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Utf8>)
      >('fs_set_runtime_environment');
  for (final entry in values) {
    final key = entry.key.toNativeUtf8(), value = entry.value.toNativeUtf8();
    try {
      if (configure(key, value) != 0)
        throw StateError('Cannot configure native runtime ${entry.key}');
    } finally {
      calloc.free(key);
      calloc.free(value);
    }
  }
  _nativeEnvironmentConfigured = true;
}

void configureProfileRuntime(String data) {
  runtimeConfiguration.environment.putIfAbsent(
    'FORESIGHT_LITERT_CACHE',
    () => '$data/cache/litert',
  );
  runtimeConfiguration.environment.putIfAbsent(
    'PYTHONPYCACHEPREFIX',
    () => '$data/cache/python',
  );
  configureNativeEnvironment();
}
