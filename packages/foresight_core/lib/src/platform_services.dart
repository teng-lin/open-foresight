import 'native_lifetime.dart';
import 'native_diagnostics.dart';
import 'profile_paths.dart';
import 'installation_lock.dart';
export 'installation_lock.dart' show InstallationLock;
import 'package:crypto/crypto.dart';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'dart:convert';
import 'dart:io';

const foresightTestHooksEnabled = bool.fromEnvironment(
  'FORESIGHT_ENABLE_TEST_HOOKS',
);
const _testHookKeys = {
  'FORESIGHT_TEST_DESKTOP_EXECUTABLE',
  'FORESIGHT_CRASH_AT',
  'FORESIGHT_TEST_DELAY_MS',
  'FORESIGHT_SERVICE_GATES',
  // How long `--stop` waits for the owner to release its profile.
  'FORESIGHT_TEST_STOP_RELEASE_MS',
};

/// The same immutable resource map is used by Finder, MCP and detached workers.
/// Paths in runtime.json are relative to the bundle's resources, never the cwd.
const _scalarRuntimeKeys = {
  'FORESIGHT_LITERT_BACKEND',
  'FORESIGHT_RUNTIME_REVISION',
  'FORESIGHT_SEARCH_API_KEY',
  'FORESIGHT_WEB_CONTENT_API_KEY',
  'FORESIGHT_QUERY_TERMS_URL',
  'FORESIGHT_WHISPER_BACKEND',
  'FORESIGHT_WHISPER_DEVICE',
  'FORESIGHT_MICROPHONE_TARGET',
  'FORESIGHT_PLAYBACK_TARGET',
  'FORESIGHT_TEST_DELAY_MS',
  'FORESIGHT_CRASH_AT',
};

const _bundledAuthoritativeScalarKeys = {
  'FORESIGHT_RUNTIME_REVISION',
  'FORESIGHT_QUERY_TERMS_URL',
};

String? _linuxBundleRoot(String executable) {
  final file = File(executable);
  final path = file.existsSync()
      ? file.resolveSymbolicLinksSync()
      : file.absolute.path;
  final entry = File(path);
  final directory = entry.parent.path.split(Platform.pathSeparator).last;
  final name = entry.uri.pathSegments.last;
  if (!((directory == 'bin' &&
          {'foresight-service', 'foresight-mcp'}.contains(name)) ||
      (directory == 'app' && name == 'open-foresight'))) {
    return null;
  }
  final root = entry.parent.parent;
  if (!Directory('${root.path}/app').existsSync() ||
      !Directory('${root.path}/lib').existsSync()) {
    return null;
  }
  return root.resolveSymbolicLinksSync();
}

/// Runtime configuration. Public construction yields an immutable snapshot: it
/// copies [environment], so neither the caller's map nor the exposed view can
/// change it. Only the legacy process/isolate boundary ([runtimeConfiguration])
/// keeps an editable map; owners capture it with [snapshot].
class RuntimeConfiguration {
  final Map<String, String> environment;
  final String? linuxBundleRoot;
  final bool _snapshot;
  RuntimeConfiguration(Map<String, String> environment, {this.linuxBundleRoot})
    : environment = Map.unmodifiable(environment),
      _snapshot = true;

  /// The legacy boundary's editable map, retained for callers outside the
  /// injected ports. Never handed to an owner without [snapshot].
  RuntimeConfiguration._boundary(this.environment, {this.linuxBundleRoot})
    : _snapshot = false;

  /// Whether this is an immutable snapshot rather than the legacy boundary.
  bool get isSnapshot => _snapshot;

  /// An immutable copy; a snapshot is returned as is.
  RuntimeConfiguration snapshot() => _snapshot
      ? this
      : RuntimeConfiguration(environment, linuxBundleRoot: linuxBundleRoot);

  /// A frontend's already resolved map in this process's service runtime.
  factory RuntimeConfiguration.serviceWorker(Map<String, String> environment) =>
      RuntimeConfiguration(
        environment,
        linuxBundleRoot: _linuxBundleRoot(Platform.resolvedExecutable),
      );
  factory RuntimeConfiguration.resolve({
    Map<String, String>? environment,
    String? executable,
  }) {
    final values = Map<String, String>.from(
      environment ?? Platform.environment,
    );
    final startup = values.remove('FORESIGHT_STARTUP_ENV');
    if (startup != null) {
      values.addAll(consumeServiceStartupEnvironment(startup));
    }
    final path = executable ?? Platform.resolvedExecutable;
    final marker = path.lastIndexOf('.app/Contents/');
    final linuxRoot = _linuxBundleRoot(path);
    final bundled = marker >= 0 || linuxRoot != null;
    // Keep Linux's existing scalar opt-ins; this boundary owns code paths and
    // the installation revision. Mac's distribution-owned terms stay sealed.
    final authoritativeScalars = linuxRoot == null
        ? _bundledAuthoritativeScalarKeys
        : const {'FORESIGHT_RUNTIME_REVISION'};
    if (bundled) {
      // Resource/code selection belongs to the installed application. A private
      // handoff authenticates file ownership, not the supplied library paths.
      values.removeWhere(
        (key, _) =>
            key.startsWith('FORESIGHT_') &&
            !{
              ..._scalarRuntimeKeys.where(
                (key) => !authoritativeScalars.contains(key),
              ),
              'FORESIGHT_DATA',
              'FORESIGHT_RUNTIME',
              'FORESIGHT_SERVICE_TRACE',
              // The service checks that it names a file in its runtime.
              'FORESIGHT_STARTUP_STATUS',
              if (linuxRoot != null) 'FORESIGHT_MODEL_MANIFEST',
            }.contains(key),
      );
    }
    final resources =
        (bundled ? null : values['FORESIGHT_RESOURCES']) ??
        (linuxRoot != null
            ? '$linuxRoot/share/open-foresight'
            : marker < 0
            ? null
            : '${path.substring(0, marker + 4)}/Contents/Resources');
    if (resources != null) {
      final file = File('$resources/runtime.json');
      if (bundled && !file.existsSync()) {
        throw StateError(
          'The application runtime configuration is missing. Reinstall Open Foresight.',
        );
      }
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
          final value =
              _scalarRuntimeKeys.contains(entry.key) || relative.startsWith('/')
              ? relative
              : '$resources/$relative';
          if (bundled &&
              (!_scalarRuntimeKeys.contains(entry.key) ||
                  authoritativeScalars.contains(entry.key))) {
            values[entry.key] = value;
          } else {
            values.putIfAbsent(entry.key, () => value);
          }
        }
      }
      values['FORESIGHT_RESOURCES'] = resources;
      if (bundled && !values.containsKey('FORESIGHT_NATIVE')) {
        throw StateError(
          'The application native runtime is missing. Reinstall Open Foresight.',
        );
      }
      if (linuxRoot != null) {
        values['FORESIGHT_INSTALL_ROOT'] = linuxRoot;
        final libraries = ['$linuxRoot/lib', '$linuxRoot/app/lib'];
        values['LD_LIBRARY_PATH'] = [
          ...libraries,
          ...?values['LD_LIBRARY_PATH']
              ?.split(':')
              .where((path) => path.isNotEmpty && !libraries.contains(path)),
        ].join(':');
        if ((values['FORESIGHT_RUNTIME_REVISION'] ?? '').isEmpty) {
          throw StateError(
            'The application runtime revision is missing. Reinstall Open Foresight.',
          );
        }
      }
      if (bundled) {
        values.removeWhere(
          (key, _) => key.startsWith('FORESIGHT_DEVELOPMENT_'),
        );
      }
    }
    if (!foresightTestHooksEnabled) {
      for (final key in _testHookKeys) {
        values.remove(key);
      }
    }
    return RuntimeConfiguration(values, linuxBundleRoot: linuxRoot);
  }
  String? operator [](String key) => environment[key];
  String get nativeLibrary =>
      this['FORESIGHT_NATIVE'] ??
      (Platform.isMacOS
          ? 'libforesight_native.dylib'
          : 'libforesight_native.so');
  String? get installationRoot => switch (this['FORESIGHT_INSTALL_ROOT']) {
    final String root => canonicalProfilePath(root),
    null => null,
  };

  /// A new snapshot where explicit values win over [defaults].
  RuntimeConfiguration withDefaults(Map<String, String> defaults) =>
      defaults.keys.every(environment.containsKey)
      ? snapshot()
      : RuntimeConfiguration({
          ...defaults,
          ...environment,
        }, linuxBundleRoot: linuxBundleRoot);

  /// A new snapshot where [values] replace entries; a null value removes one.
  RuntimeConfiguration withOverrides(Map<String, String?> values) =>
      RuntimeConfiguration({
        for (final entry in environment.entries)
          if (!values.containsKey(entry.key)) entry.key: entry.value,
        for (final entry in values.entries)
          if (entry.value case final String value) entry.key: value,
      }, linuxBundleRoot: linuxBundleRoot);

  /// Profile-owned caches for native and Python workers of the [data] profile.
  RuntimeConfiguration withProfileRuntime(String data) =>
      withDefaults(_profileRuntimeDefaults(data));
}

Map<String, String> _profileRuntimeDefaults(String data) => {
  'FORESIGHT_LITERT_CACHE': '$data/cache/litert',
  'PYTHONPYCACHEPREFIX': '$data/cache/python',
};

RuntimeConfiguration? _runtimeConfiguration;

/// The legacy process/isolate boundary, resolved lazily on first use. Its
/// environment stays editable for callers outside the injected ports;
/// composition roots capture it once with [runtimeSnapshot].
RuntimeConfiguration get runtimeConfiguration =>
    _runtimeConfiguration ??= _legacyBoundary(RuntimeConfiguration.resolve());

/// An immutable snapshot of [configuration], or of the boundary when omitted.
/// Every owner capture uses this, so no port holds the editable boundary.
RuntimeConfiguration runtimeSnapshot([RuntimeConfiguration? configuration]) =>
    (configuration ?? runtimeConfiguration).snapshot();

RuntimeConfiguration _legacyBoundary(RuntimeConfiguration configuration) =>
    configuration.isSnapshot
    ? RuntimeConfiguration._boundary(
        Map.of(configuration.environment),
        linuxBundleRoot: configuration.linuxBundleRoot,
      )
    : configuration;

/// Install the frontend's resolved map before any worker runtime access. The
/// process environment still names the handoff already consumed by the frontend.
void installServiceWorkerEnvironment(Map<String, String> environment) {
  _runtimeConfiguration = _legacyBoundary(
    RuntimeConfiguration.serviceWorker(environment),
  );
}

/// Install a snapshot transported from another isolate as this isolate's
/// boundary (an editable copy), or restore a previous boundary in tests.
/// Returns the boundary it replaced without resolving one: a worker's process
/// handoff may already be consumed.
RuntimeConfiguration? installRuntimeConfiguration(
  RuntimeConfiguration configuration,
) {
  final previous = _runtimeConfiguration;
  _runtimeConfiguration = _legacyBoundary(configuration);
  return previous;
}

// mode_t is unsigned short on Darwin and unsigned int on Linux. Calling libc
// directly avoids starting a child process while publishing a local socket.
/// Consume one private, bounded startup handoff before resolving resources.
Map<String, String> consumeServiceStartupEnvironment(String path) {
  final file = File(path);
  if (file.uri.pathSegments.last != 'startup.json' ||
      !file.parent.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith('of-launch-') ||
      FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw StateError('Invalid service environment handoff');
  }
  privateDirectory(file.parent.path);
  if ((file.statSync().mode & 0x1ff) != 0x180 || file.lengthSync() > 65536) {
    throw StateError('Service environment handoff must be private and bounded');
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map ||
      decoded.entries.any(
        (e) =>
            e.key is! String ||
            e.value is! String ||
            (!(e.key as String).startsWith('FORESIGHT_') &&
                e.key != 'PYTHONPYCACHEPREFIX') ||
            e.key == 'FORESIGHT_STARTUP_ENV',
      )) {
    throw StateError('Invalid service environment entries');
  }
  final result = Map<String, String>.from(decoded);
  file.deleteSync();
  file.parent.deleteSync();
  return result;
}

final int Function(Pointer<Utf8>, int) _chmod = Platform.isMacOS
    ? DynamicLibrary.process().lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint16),
        int Function(Pointer<Utf8>, int)
      >('chmod')
    : DynamicLibrary.process().lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');

final int Function(Pointer<Utf8>, int) _mkdir = Platform.isMacOS
    ? DynamicLibrary.process().lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint16),
        int Function(Pointer<Utf8>, int)
      >('mkdir')
    : DynamicLibrary.process().lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('mkdir');

/// Set mode 0600 before exposing a private local endpoint to its clients.
void protectPrivateFile(String path) {
  if (path.contains('\u0000')) {
    throw ArgumentError.value(path, 'path', 'Path contains a NUL character');
  }
  final nativePath = path.toNativeUtf8(allocator: calloc);
  try {
    if (_chmod(nativePath, 0x180) != 0) {
      throw FileSystemException('Cannot protect private file', path);
    }
  } finally {
    calloc.free(nativePath);
  }
}

/// Create or check [profile]'s runtime directory as private, and the
/// directory a default runtime lives in too (S5). An owned parent that only
/// its user can write is tightened like the profile itself.
void privateRuntime(ProfilePaths profile) {
  final parent = profile.runtimeParent;
  if (parent != null) privateDirectory(parent, repairOwnedPermissions: true);
  privateDirectory(profile.runtime);
}

/// Refuse symlinks and foreign/public directories before using local RPC state.
void privateDirectory(String path, {bool repairOwnedPermissions = false}) {
  final dir = Directory(path);
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw StateError('Private directory must not be a symbolic link: $path');
  }
  if (!dir.existsSync()) {
    if (path.contains('\u0000')) {
      throw StateError('Private directory path contains a NUL character');
    }
    dir.parent.createSync(recursive: true);
    // Create it with mode 0700: a directory created first and protected after
    // looks public to another creator in between, such as a client resolving
    // the endpoint while its owner starts, which then refuses it.
    final nativePath = path.toNativeUtf8(allocator: calloc);
    try {
      if (_mkdir(nativePath, 0x1c0) == 0) {
        // A umask stricter than 077 can strip the owner's own bits.
        if ((dir.statSync().mode & 0x1ff) != 0x1c0 &&
            _chmod(nativePath, 0x1c0) != 0) {
          throw StateError('Cannot protect $path');
        }
      } else if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        // Not another creator winning the race. Creating it again reports
        // the reason, such as a file in the way or an unwritable parent.
        dir.createSync();
        throw FileSystemException('Cannot create private directory', path);
      }
      // Otherwise another creator won the race; the checks below decide.
    } finally {
      calloc.free(nativePath);
    }
  }
  final owner = Process.runSync(
    '/usr/bin/stat',
    Platform.isMacOS ? ['-f', '%u', path] : ['-Lc', '%u', path],
  );
  final user = Process.runSync('/usr/bin/id', ['-u']);
  if (owner.exitCode != 0 ||
      user.exitCode != 0 ||
      owner.stdout.toString().trim() != user.stdout.toString().trim()) {
    throw StateError('Requires private user-owned directory: $path');
  }
  final mode = dir.statSync().mode;
  // Older installations created the application profile with the normal 0755
  // umask. Tighten that owned profile without touching its data or descendants.
  // Never adopt a directory other users could have modified, or relax checks
  // for arbitrary RPC/runtime/handoff directories.
  if (repairOwnedPermissions && (mode & 0x3f) != 0 && (mode & 0x12) == 0) {
    if (Process.runSync('/bin/chmod', ['700', path]).exitCode != 0) {
      throw StateError('Cannot protect $path');
    }
    privateDirectory(path);
    return;
  }
  if ((mode & 0x3f) != 0) {
    throw StateError('Requires private user-owned directory: $path');
  }
}

final _mkdtemp = DynamicLibrary.process()
    .lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)
    >('mkdtemp');

/// Create a temporary directory atomically with mode 0700 via POSIX mkdtemp.
/// Dart's Linux createTemp honors umask and can otherwise expose mode 0755.
/// Keep privateDirectory strict for existing caller-supplied directories.
Future<Directory> createPrivateTempDirectory(
  Directory parent,
  String prefix,
) async {
  if (prefix.contains('/')) {
    throw ArgumentError.value(
      prefix,
      'prefix',
      'Temporary directory prefix must not contain path separators',
    );
  }
  final template = '${parent.path}/${prefix}XXXXXX'.toNativeUtf8();
  final String createdPath;
  try {
    final result = _mkdtemp(template);
    if (result == nullptr) {
      throw FileSystemException(
        'Cannot create private temporary directory',
        parent.path,
      );
    }
    createdPath = result.toDartString();
  } finally {
    calloc.free(template);
  }
  final directory = Directory(createdPath);
  try {
    if ((directory.statSync().mode & 0x1ff) != 0x1c0) {
      final result = await Process.run('/bin/chmod', ['700', directory.path]);
      if (result.exitCode != 0) {
        throw StateError('Cannot protect ${directory.path}');
      }
    }
    privateDirectory(directory.path);
    if (directory.listSync(followLinks: false).isNotEmpty) {
      throw StateError(
        'Private temporary directory must be empty: ${directory.path}',
      );
    }
    return directory;
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
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

bool allowedSourceUri(Uri uri) {
  if (uri.userInfo.isNotEmpty) return false;
  if (uri.scheme == 'https' || uri.scheme == 'http') return uri.host.isNotEmpty;
  return uri.scheme == 'file' &&
      (uri.host.isEmpty || uri.host == 'localhost') &&
      uri.path.startsWith('/') &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

/// Until grants can distinguish imported files, reveal local paths instead of
/// invoking their default application (which can execute scripts on macOS).
({String executable, List<String> arguments}) platformUriLaunch(
  Uri uri, {
  bool? macOS,
}) {
  if (!allowedSourceUri(uri)) {
    throw ArgumentError.value(uri, 'uri', 'Unsupported source URI');
  }
  final mac = macOS ?? Platform.isMacOS;
  if (uri.scheme == 'file') {
    final path = uri.toFilePath();
    if (mac) {
      return (executable: '/usr/bin/open', arguments: ['-R', '--', path]);
    }
    return (
      executable: '/usr/bin/dbus-send',
      arguments: [
        '--session',
        '--dest=org.freedesktop.FileManager1',
        '--type=method_call',
        '/org/freedesktop/FileManager1',
        'org.freedesktop.FileManager1.ShowItems',
        // dbus-send splits array elements on literal commas. Keep a comma
        // in the file name inside its URI rather than creating another item.
        'array:string:${Uri.file(path).toString().replaceAll(',', '%2C')}',
        'string:',
      ],
    );
  }
  return (
    executable: mac ? '/usr/bin/open' : '/usr/bin/xdg-open',
    arguments: [uri.toString()],
  );
}

Future<void> openPlatformUri(Uri uri) async {
  final launch = platformUriLaunch(uri);
  final result = await Process.run(launch.executable, launch.arguments);
  if (result.exitCode != 0) {
    throw StateError('Could not open $uri: ${result.stderr}');
  }
}

Future<void> platformNotification(
  String title,
  String message, {
  RuntimeConfiguration? configuration,
}) async {
  final helper = runtimeSnapshot(configuration)['FORESIGHT_NOTIFICATIONS'];
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
      : await Process.run('/usr/bin/notify-send', [title, message]);
  if (result.exitCode != 0) {
    throw StateError(
      'Notification delivery failed. ${_notificationFailure(result)}',
    );
  }
}

const _nativeEnvironmentKeys = {
  'FORESIGHT_LITERT_LIBRARY',
  'FORESIGHT_LITERT_BACKEND',
  'FORESIGHT_WHISPER_BACKEND',
  'FORESIGHT_WHISPER_DEVICE',
  'FORESIGHT_HELPER',
  'FORESIGHT_LITERT_CACHE',
  'FORESIGHT_WHISPER_RUNTIME',
  'FORESIGHT_WHISPER_WORKER',
  'PYTHONPYCACHEPREFIX',
  'LD_LIBRARY_PATH',
  'FORESIGHT_LOG_LEVEL',
};
bool _nativeEnvironmentConfigured = false;

/// Configure C/C++ getenv consumers once, before service-owned workers start.
/// Dart's resource map does not otherwise modify the process environment.
void configureNativeEnvironment({RuntimeConfiguration? configuration}) {
  if (_nativeEnvironmentConfigured) return;
  final config = runtimeSnapshot(configuration);
  final values = config.environment.entries
      .where(
        (entry) =>
            _nativeEnvironmentKeys.contains(entry.key) &&
            entry.key != 'FORESIGHT_LOG_LEVEL' &&
            entry.value.isNotEmpty,
      )
      .toList();
  late final DynamicLibrary selected;
  try {
    selected = DynamicLibrary.open(config.nativeLibrary);
  } on ArgumentError {
    if (values.isNotEmpty || config['FORESIGHT_NATIVE'] != null) {
      rethrow;
    }
    // A SQL-only development worker may have no native mapping available.
    // A selected/mapped native-capable replacement still passes the gate below.
    _nativeEnvironmentConfigured = true;
    return;
  }
  final bindings = NativeLibrary(selected);
  final lib = bindings.library;
  // This runs after installation/profile ownership is acquired. A worker lost
  // with native work cannot be replaced in the same mapped process, even from
  // another frontend isolate. Base-only runtimes keep their optional contract.
  if (lib.providesSymbol('fs_lifetime_admission') &&
      lib.lookupFunction<Int32 Function(), int Function()>(
            'fs_lifetime_admission',
          )() !=
          1) {
    throw StateError('Native ownership is unconfirmed; restart the service');
  }
  final loggingLevel = NativeLibrary.diagnosticLevel;
  final loggingCapable =
      loggingLevel != null &&
      NativeDiagnosticQueueFunctions.fromLoaded(bindings) != null;
  if (values.isEmpty && !loggingCapable) {
    _nativeEnvironmentConfigured = true;
    return;
  }
  final configure =
      lib.providesSymbol('fs_set_runtime_environment') || values.isNotEmpty
      ? lib.lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('fs_set_runtime_environment')
      : null;
  for (final entry in values) {
    final key = entry.key.toNativeUtf8(), value = entry.value.toNativeUtf8();
    try {
      if (configure!(key, value) != 0) {
        throw StateError('Cannot configure native runtime ${entry.key}');
      }
    } finally {
      calloc.free(key);
      calloc.free(value);
    }
  }
  if (loggingCapable) {
    final key = 'FORESIGHT_LOG_LEVEL'.toNativeUtf8();
    final value = loggingLevel.toNativeUtf8();
    try {
      if (configure == null || configure(key, value) != 0) {
        try {
          NativeLibrary.diagnosticConfigurationUnavailable?.call();
        } catch (_) {}
      }
    } finally {
      calloc.free(key);
      calloc.free(value);
    }
  }
  _nativeEnvironmentConfigured = true;
}

/// Add the [data] profile's cache defaults and configure native consumers from
/// the resulting snapshot, which is returned. Without a snapshot the legacy
/// boundary receives the defaults in place, as its other callers expect; a
/// caller's snapshot is never changed.
RuntimeConfiguration configureProfileRuntime(
  String data, {
  RuntimeConfiguration? configuration,
}) {
  final RuntimeConfiguration profiled;
  if (configuration != null && configuration.isSnapshot) {
    profiled = configuration.withProfileRuntime(data);
  } else {
    final boundary = configuration ?? runtimeConfiguration;
    _profileRuntimeDefaults(data).forEach(
      (key, value) => boundary.environment.putIfAbsent(key, () => value),
    );
    profiled = boundary.snapshot();
  }
  configureNativeEnvironment(configuration: profiled);
  return profiled;
}

String _notificationFailure(ProcessResult result) {
  try {
    final body = jsonDecode(result.stdout.toString());
    if (body is Map &&
        body['error'] is String &&
        (body['error'] as String).isNotEmpty) {
      return body['error'] as String;
    }
  } on FormatException {
    /* Linux notify-send reports failures on stderr. */
  }
  final detail = result.stderr.toString().trim();
  return detail.isEmpty
      ? 'Check notification permission in System Settings.'
      : detail;
}

Future<Map<String, dynamic>> notificationCapabilities({
  bool requestPermission = false,
  RuntimeConfiguration? configuration,
}) async {
  if (!Platform.isMacOS) {
    return {
      'available': File('/usr/bin/notify-send').existsSync(),
      'backend': 'freedesktop',
    };
  }
  final helper = runtimeSnapshot(configuration)['FORESIGHT_NOTIFICATIONS'];
  if (helper == null) {
    throw StateError(
      'The bundled notification adapter is unavailable. Reinstall Open Foresight.',
    );
  }
  final result = await Process.run(helper, [
    requestPermission ? '--request-permission' : '--capabilities',
  ]);
  final body = Map<String, dynamic>.from(
    jsonDecode(result.stdout.toString()) as Map,
  );
  if (result.exitCode != 0 && body['granted'] != false) {
    throw StateError(_notificationFailure(result));
  }
  return body;
}

/// Shared with tools/install_macos.py. A stable per-installation lock covers all
/// profiles, including clients launched during the installer's final app swap.
String installationLockPath(String appRoot) {
  final canonical = canonicalProfilePath(appRoot);
  final identity = sha256
      .convert(utf8.encode(canonical))
      .toString()
      .substring(0, 24);
  final home = installationLockHome();
  final cache = Platform.isMacOS
      ? '$home/Library/Caches/io.openforesight.App'
      : '$home/.cache/open-foresight';
  return '$cache/install-locks/$identity/lock';
}

InstallationLock? acquireInstallationLock({
  RuntimeConfiguration? configuration,
}) {
  final root = runtimeSnapshot(configuration)['FORESIGHT_INSTALL_ROOT'];
  if (root == null) return null;
  void refuseMaintenance() {
    if (FileSystemEntity.typeSync(
          '${canonicalProfilePath(root)}/.installation-maintenance',
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      throw StateError(
        'An Open Foresight update is in progress or was interrupted. Complete installation before launching.',
      );
    }
  }

  refuseMaintenance();
  final lock = InstallationLock.acquire(installationLockPath(root));
  try {
    // The installer publishes its marker before probing locks. This recheck
    // closes the gap if it publishes between our initial check and acquisition.
    refuseMaintenance();
    return lock;
  } catch (_) {
    lock.closeSync();
    rethrow;
  }
}

String? get configuredInstallationRoot => runtimeConfiguration.installationRoot;

/// A packaged client may attach only to its own installed application revision.
/// Development clients without a packaged revision retain the existing contract.
void validateServiceCompatibility(
  Map status, {
  RuntimeConfiguration? configuration,
}) {
  final config = runtimeSnapshot(configuration);
  final revision = config['FORESIGHT_RUNTIME_REVISION'];
  if (revision == null) return;
  final root = config['FORESIGHT_INSTALL_ROOT'];
  if (root == null) {
    throw StateError(
      'The application runtime configuration is missing its installation root. Reinstall Open Foresight.',
    );
  }
  if (status['application_api_version'] != 1 ||
      status['runtime_revision'] != revision ||
      status['installation_root'] != canonicalProfilePath(root)) {
    throw StateError(
      'This profile is owned by a different Open Foresight installation or revision. Stop the existing application service explicitly, then launch this installation again. No requests have been replayed.',
    );
  }
}

/// Publish sensitive text only after its temporary file has mode 0600.
/// Rename replaces a selected symlink rather than following it.
Future<void> writePrivateTextFile(File destination, String text) async {
  final staging = await createPrivateTempDirectory(
    destination.absolute.parent,
    '.foresight-export-',
  );
  final file = File('${staging.path}/content');
  try {
    await file.create();
    final protected = await Process.run('/bin/chmod', ['600', file.path]);
    if (protected.exitCode != 0 || (file.statSync().mode & 0x1ff) != 0x180) {
      throw StateError('Cannot protect export file');
    }
    await file.writeAsString(text, flush: true);
    await file.rename(destination.absolute.path);
  } finally {
    await staging.delete(recursive: true);
  }
}

/// Called only while the service owns the profile lock.
void sweepStaleSpeechAudio(String profile) {
  final directory = Directory('$profile/speech');
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return;
  }
  for (final entry in directory.listSync(followLinks: false)) {
    if (entry.uri.pathSegments.last.startsWith('foresight-asr-') &&
        entry is File) {
      entry.deleteSync();
    }
  }
}
