import 'profile_paths.dart';
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
/// Paths in runtime.json are relative to Contents/Resources, never the cwd.
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
    final startup = values.remove('FORESIGHT_STARTUP_ENV');
    if (startup != null) {
      values.addAll(consumeServiceStartupEnvironment(startup));
    }
    final path = executable ?? Platform.resolvedExecutable;
    final marker = path.lastIndexOf('.app/Contents/');
    final bundled = marker >= 0;
    if (bundled) {
      // Resource/code selection belongs to the signed application. A private
      // handoff authenticates file ownership, not the supplied library paths.
      values.removeWhere(
        (key, _) =>
            key.startsWith('FORESIGHT_') &&
            !{
              ..._scalarRuntimeKeys.where(
                (key) => !_bundledAuthoritativeScalarKeys.contains(key),
              ),
              'FORESIGHT_DATA',
              'FORESIGHT_RUNTIME',
              'FORESIGHT_SERVICE_TRACE',
              // The service checks that it names a file in its runtime.
              'FORESIGHT_STARTUP_STATUS',
            }.contains(key),
      );
    }
    final resources =
        (bundled ? null : values['FORESIGHT_RESOURCES']) ??
        (marker < 0
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
                  _bundledAuthoritativeScalarKeys.contains(entry.key))) {
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
    }
    if (!foresightTestHooksEnabled) {
      for (final key in _testHookKeys) {
        values.remove(key);
      }
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

RuntimeConfiguration? _runtimeConfiguration;
RuntimeConfiguration get runtimeConfiguration =>
    _runtimeConfiguration ??= RuntimeConfiguration.resolve();

/// Install the frontend's resolved map before any worker runtime access. The
/// process environment still names the handoff already consumed by the frontend.
void installServiceWorkerEnvironment(Map<String, String> environment) {
  _runtimeConfiguration = RuntimeConfiguration(
    Map<String, String>.from(environment),
  );
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
      if (configure(key, value) != 0) {
        throw StateError('Cannot configure native runtime ${entry.key}');
      }
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
}) async {
  if (!Platform.isMacOS) {
    return {
      'available': File('/usr/bin/notify-send').existsSync(),
      'backend': 'freedesktop',
    };
  }
  final helper = runtimeConfiguration['FORESIGHT_NOTIFICATIONS'];
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
  final result = Process.runSync('/usr/bin/id', ['-u']);
  final uid = result.stdout.toString().trim();
  if (result.exitCode != 0 || int.tryParse(uid) == null) {
    throw StateError('Cannot determine installation lock owner');
  }
  final identity = sha256
      .convert(utf8.encode(canonical))
      .toString()
      .substring(0, 24);
  return '/tmp/of-install-$uid-$identity/lock';
}

RandomAccessFile? acquireInstallationLock() {
  final root = runtimeConfiguration['FORESIGHT_INSTALL_ROOT'];
  if (root == null) return null;
  final path = installationLockPath(root);
  privateDirectory(File(path).parent.path);
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw StateError('Installation lock must not be a symbolic link');
  }
  final lock = File(path).openSync(mode: FileMode.append);
  try {
    if (Process.runSync('/bin/chmod', ['600', path]).exitCode != 0) {
      throw StateError('Cannot protect installation lock');
    }
    try {
      lock.lockSync(FileLock.shared);
    } on FileSystemException {
      throw StateError(
        'An Open Foresight update is in progress. Retry launching after installation finishes.',
      );
    }
    return lock;
  } catch (_) {
    lock.closeSync();
    rethrow;
  }
}

String? get configuredInstallationRoot {
  final root = runtimeConfiguration['FORESIGHT_INSTALL_ROOT'];
  return root == null ? null : canonicalProfilePath(root);
}

/// A packaged client may attach only to its own installed application revision.
/// Development clients without a packaged revision retain the existing contract.
void validateServiceCompatibility(
  Map status, {
  RuntimeConfiguration? configuration,
}) {
  final config = configuration ?? runtimeConfiguration;
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
