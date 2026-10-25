/// System-only startup authority. This module must not import application,
/// profile, SQLite, platform_services or another diagnostic session.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'configuration.dart';
import 'storage_worker_launch.dart';
import 'storage_worker_native.dart';
import 'storage_worker_source.dart';

enum DiagnosticHost { service, mcp, desktop, standaloneWorker }

enum DiagnosticWorkerInvocationKind { absent, valid, invalid }

final class DiagnosticWorkerInvocation {
  const DiagnosticWorkerInvocation._(this.kind, this.parentPid, this.support);
  final DiagnosticWorkerInvocationKind kind;
  final int? parentPid;
  final String? support;

  /// Parse before consulting environment/configuration or loading any image.
  static DiagnosticWorkerInvocation parse(List<String> arguments) {
    if (!arguments.any(
      (argument) =>
          argument.startsWith('--diagnostic-storage-worker') ||
          argument.startsWith('--diagnostic-native-support'),
    )) {
      return const DiagnosticWorkerInvocation._(
        DiagnosticWorkerInvocationKind.absent,
        null,
        null,
      );
    }
    if (arguments.length != 4 ||
        arguments[0] != '--diagnostic-storage-worker' ||
        arguments[2] != '--diagnostic-native-support' ||
        !RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(arguments[1])) {
      return const DiagnosticWorkerInvocation._(
        DiagnosticWorkerInvocationKind.invalid,
        null,
        null,
      );
    }
    final parent = int.tryParse(arguments[1]);
    final support = arguments[3];
    if (parent == null ||
        parent <= 1 ||
        parent > 0x7fffffff ||
        !_absolute(support)) {
      return const DiagnosticWorkerInvocation._(
        DiagnosticWorkerInvocationKind.invalid,
        null,
        null,
      );
    }
    return DiagnosticWorkerInvocation._(
      DiagnosticWorkerInvocationKind.valid,
      parent,
      support,
    );
  }
}

bool _absolute(String value) =>
    value.isNotEmpty &&
    value.length <= 1024 &&
    !value.codeUnits.any((c) => c < 32 || c == 127) &&
    p.isAbsolute(value) &&
    p.normalize(value) == value;

bool _identity(String value) =>
    value.length == 64 &&
    value.codeUnits.every((c) => (c >= 48 && c <= 57) || (c >= 97 && c <= 102));

bool _linuxInstallationEntry(String executable) {
  final directory = p.basename(p.dirname(executable));
  final name = p.basename(executable);
  return directory == 'bin' &&
          const {'foresight-service', 'foresight-mcp'}.contains(name) ||
      directory == 'app' && name == 'open-foresight';
}

bool _sourceSelected(DiagnosticStartupContext context) {
  if (!context.sourceContext) return false;
  if (context.executable.contains('.app/Contents/')) {
    return !context.product && !context.profile;
  }
  // Copied installed bytes cannot retain authority over their old build root.
  return !_linuxInstallationEntry(context.executable);
}

/// Build-selected public values, never populated from runtime environment.
/// A source test context must be explicit at compilation. Missing reviewed
/// worker identity leaves logging unavailable without opening candidates.
final class DiagnosticStartupContext {
  const DiagnosticStartupContext({
    required this.host,
    required this.executable,
    required this.script,
    required this.nativeId,
    required this.dartId,
    required this.catalogId,
    required this.workerMode,
    this.sourceAnchor = '',
    this.buildRoot = '',
    this.sourceContext = false,
    this.dartExecutable = '',
    this.dartSdkRoot = '',
    this.dartSdkIdentity = '',
    this.packageConfig = '',
    this.sourceWorker = '',
    this.kernelWorker = '',
    this.product = false,
    this.profile = false,
    this.macOS = false,
  });
  final DiagnosticHost host;
  final String executable, script, nativeId, dartId, catalogId, workerMode;
  final String buildRoot;
  String get selectedBuildRoot =>
      buildRoot.isEmpty ? p.join(sourceAnchor, 'build') : buildRoot;
  final String sourceAnchor,
      dartExecutable,
      dartSdkRoot,
      dartSdkIdentity,
      packageConfig;
  final String sourceWorker, kernelWorker;
  final bool sourceContext, product, profile, macOS;

  factory DiagnosticStartupContext.current(DiagnosticHost host) {
    const descriptor = String.fromEnvironment(
      'FORESIGHT_DIAGNOSTIC_SOURCE_DESCRIPTOR',
    );

    Map<String, Object?>? source;
    if (descriptor.isNotEmpty) {
      try {
        if (descriptor.length > 1024) _refuse();
        final value = jsonDecode(utf8.decode(base64Url.decode(descriptor)));
        const keys = {
          'schema',
          'anchor',
          'build',
          'dart',
          'packages',
          'source',
          'kernel',
          'mode',
          'sdk',
          'sdk_id',
        };
        if (value is! Map<String, dynamic> ||
            value.length != keys.length ||
            !value.keys.every(keys.contains) ||
            value['schema'] != 1 ||
            value.entries.any(
              (entry) => entry.key != 'schema' && entry.value is! String,
            )) {
          _refuse();
        }
        source = value;
      } catch (_) {
        _refuse();
      }
    }
    return DiagnosticStartupContext(
      host: host,
      executable: Platform.resolvedExecutable,
      script: Platform.script.scheme == 'file'
          ? Platform.script.toFilePath()
          : '',
      nativeId: const String.fromEnvironment('FORESIGHT_DIAGNOSTIC_NATIVE_ID'),
      dartId: const String.fromEnvironment('FORESIGHT_DIAGNOSTIC_BUILD_ID'),
      catalogId: const String.fromEnvironment(
        'FORESIGHT_DIAGNOSTIC_CATALOG_ID',
      ),
      workerMode:
          source?['mode'] as String? ??
          const String.fromEnvironment('FORESIGHT_DIAGNOSTIC_WORKER_MODE'),
      sourceAnchor:
          source?['anchor'] as String? ??
          const String.fromEnvironment('FORESIGHT_DIAGNOSTIC_SOURCE_ANCHOR'),
      buildRoot:
          source?['build'] as String? ??
          const String.fromEnvironment('FORESIGHT_DIAGNOSTIC_BUILD_ROOT'),
      sourceContext:
          source != null ||
          const bool.fromEnvironment('FORESIGHT_DIAGNOSTIC_TEST_CONTEXT'),
      dartExecutable:
          source?['dart'] as String? ??
          const String.fromEnvironment('FORESIGHT_DIAGNOSTIC_DART_EXECUTABLE'),
      dartSdkRoot:
          source?['sdk'] as String? ??
          const String.fromEnvironment('FORESIGHT_DIAGNOSTIC_DART_SDK_ROOT'),
      dartSdkIdentity:
          source?['sdk_id'] as String? ??
          const String.fromEnvironment('FORESIGHT_DIAGNOSTIC_DART_SDK_ID'),
      packageConfig:
          source?['packages'] as String? ??
          const String.fromEnvironment('FORESIGHT_DIAGNOSTIC_PACKAGE_CONFIG'),
      sourceWorker:
          source?['source'] as String? ??
          const String.fromEnvironment('FORESIGHT_DIAGNOSTIC_SOURCE_WORKER'),
      kernelWorker:
          source?['kernel'] as String? ??
          const String.fromEnvironment('FORESIGHT_DIAGNOSTIC_KERNEL_WORKER'),
      product: const bool.fromEnvironment('dart.vm.product'),
      profile: const bool.fromEnvironment('dart.vm.profile'),
      macOS: Platform.isMacOS,
    );
  }

  bool get identitiesAvailable =>
      _identity(nativeId) &&
      _identity(dartId) &&
      _identity(catalogId) &&
      const {'jit', 'kernel', 'aot'}.contains(workerMode);
}

final class DiagnosticStartupUnavailable implements Exception {
  const DiagnosticStartupUnavailable();
  @override
  String toString() => 'Diagnostic startup is unavailable';
}

Never _refuse() => throw const DiagnosticStartupUnavailable();

typedef _Metadata = ({int mode, int uid, int gid, int links});

/// Metadata only: no regular candidate is opened, hashed or read here. The
/// sole regular-file open is the explicit early DynamicLibrary.open below.
_Metadata _metadata(String path) {
  final system = DynamicLibrary.process();
  final buffer = calloc<Uint8>(256);
  final name = path.toNativeUtf8();
  try {
    if (Platform.isLinux) {
      final statx = system
          .lookupFunction<
            Int32 Function(Int32, Pointer<Utf8>, Int32, Uint32, Pointer<Uint8>),
            int Function(int, Pointer<Utf8>, int, int, Pointer<Uint8>)
          >('statx');
      if (statx(-100, name, 0x100, 0x7ff, buffer) != 0) _refuse();
      final data = ByteData.sublistView(buffer.asTypedList(256));
      // TYPE|MODE|NLINK|UID|GID must all be supplied. A missing UID cannot
      // acquire root authority from the zero-initialized result buffer.
      if (data.getUint32(0, Endian.host) & 0x1f != 0x1f) _refuse();
      return (
        mode: data.getUint16(28, Endian.host),
        uid: data.getUint32(20, Endian.host),
        gid: data.getUint32(24, Endian.host),
        links: data.getUint32(16, Endian.host),
      );
    }
    if (!Platform.isMacOS) _refuse();
    final lstat = system
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Uint8>),
          int Function(Pointer<Utf8>, Pointer<Uint8>)
        >('lstat');
    if (lstat(name, buffer) != 0) _refuse();
    final data = ByteData.sublistView(buffer.asTypedList(256));
    return (
      mode: data.getUint16(4, Endian.host),
      uid: data.getUint32(16, Endian.host),
      gid: data.getUint32(20, Endian.host),
      links: data.getUint16(6, Endian.host),
    );
  } finally {
    calloc.free(name);
    calloc.free(buffer);
  }
}

int _effectiveUid() => DynamicLibrary.process()
    .lookupFunction<Uint32 Function(), int Function()>('geteuid')();

/// Closed metadata policy. Special writable ancestors are accepted only at
/// their exact physical system names; a sticky root needs a private descendant.
bool diagnosticDirectoryModeAllowed({
  required String path,
  required int mode,
  required int uid,
  required int gid,
  required int effectiveUid,
  required bool macOS,
}) {
  if (mode & 0xf000 != 0x4000 || uid != 0 && uid != effectiveUid) return false;
  if (mode & 0x12 == 0) return true;
  if (uid != 0) return false;
  final permissions = mode & 0xfff;
  if (macOS && path == '/Applications' && gid == 80 && permissions == 0x1fd) {
    return true;
  }
  if (macOS && path == '/usr/local' && gid == 20 && permissions == 0x5fd) {
    return true;
  }
  return path == (macOS ? '/private/var/tmp' : '/var/tmp') &&
      gid == 0 &&
      permissions == 0x3ff;
}

_Metadata _directory(String path) {
  final metadata = _metadata(path);
  if (!diagnosticDirectoryModeAllowed(
    path: path,
    mode: metadata.mode,
    uid: metadata.uid,
    gid: metadata.gid,
    effectiveUid: _effectiveUid(),
    macOS: Platform.isMacOS,
  )) {
    _refuse();
  }
  return metadata;
}

void _ancestors(String anchor) {
  var current = p.rootPrefix(anchor);
  var requiresPrivate = false;
  for (final part in p.split(anchor)) {
    if (part != p.rootPrefix(anchor)) current = p.join(current, part);
    final info = _directory(current);
    if (requiresPrivate) {
      if (info.uid != _effectiveUid() || info.mode & 0x3f != 0) _refuse();
      requiresPrivate = false;
    }
    if (current == (Platform.isMacOS ? '/private/var/tmp' : '/var/tmp') &&
        info.mode & 0xfff == 0x3ff) {
      requiresPrivate = true;
    }
  }
  if (requiresPrivate) _refuse();
}

void _candidate(String anchor, String path, {bool executable = false}) {
  if (!_absolute(anchor) || !_absolute(path) || !p.isWithin(anchor, path)) {
    _refuse();
  }
  _ancestors(anchor);
  var parent = anchor;
  final parts = p.split(p.relative(path, from: anchor));
  for (final component in parts.take(parts.length - 1)) {
    parent = p.join(parent, component);
    _directory(parent);
  }
  final metadata = _metadata(path);
  if (metadata.mode & 0xf000 != 0x8000 ||
      metadata.mode & 0x12 != 0 ||
      metadata.links != 1 ||
      (metadata.uid != 0 && metadata.uid != _effectiveUid()) ||
      (executable && metadata.mode & 0x49 == 0)) {
    _refuse();
  }
}

/// Mandatory SQL support selection is independent of diagnostic enablement or
/// worker identity availability. Composition loads this BEFORE any SQLite use.
final class RuntimeSupportSelection {
  const RuntimeSupportSelection._(this.anchor, this.sqlSupport);
  final String anchor, sqlSupport;

  static RuntimeSupportSelection resolve(DiagnosticStartupContext context) {
    if (!_absolute(context.executable)) _refuse();
    final marker = context.executable.indexOf('.app/Contents/');
    String anchor, support;
    if (_sourceSelected(context)) {
      anchor = context.sourceAnchor;
      if (!_absolute(anchor) ||
          marker >= 0 && !p.isWithin(anchor, context.executable)) {
        _refuse();
      }
      anchor = context.selectedBuildRoot;
      support = p.join(
        anchor,
        'native/libforesight_sql_support.${context.macOS ? 'dylib' : 'so'}',
      );
    } else if (marker >= 0) {
      anchor = context.executable.substring(0, marker + 4);
      support = p.join(
        anchor,
        'Contents/Resources/lib/libforesight_sql_support.dylib',
      );
    } else {
      final directory = p.basename(p.dirname(context.executable));
      final name = p.basename(context.executable);
      if (!((directory == 'bin' &&
              const {'foresight-service', 'foresight-mcp'}.contains(name)) ||
          (directory == 'app' && name == 'open-foresight'))) {
        _refuse();
      }
      anchor = p.dirname(p.dirname(context.executable));
      support = p.join(anchor, 'lib/libforesight_sql_support.so');
    }
    _candidate(anchor, support);
    return RuntimeSupportSelection._(anchor, support);
  }
}

/// Metadata-only command selection. Resolve only when persistence becomes
/// eligible; it never opens or hashes regular code/source files.
final class DiagnosticStartupSelection {
  DiagnosticStartupSelection._(
    this.context,
    this.anchor,
    this.launcher,
    this.support,
    this.worker,
    List<String> prefix,
  ) : prefix = List.unmodifiable(prefix);
  final DiagnosticStartupContext context;
  final String anchor, launcher, support, worker;
  final List<String> prefix;

  static DiagnosticStartupSelection resolve(DiagnosticStartupContext context) {
    if (!context.identitiesAvailable || !_absolute(context.executable)) {
      _refuse();
    }
    String anchor, worker, launcher, support;
    String? codeAnchor;
    final prefix = <String>[];
    final marker = context.executable.indexOf('.app/Contents/');
    if (_sourceSelected(context)) {
      anchor = context.sourceAnchor;
      if (!_absolute(anchor) ||
          marker >= 0 && !p.isWithin(anchor, context.executable)) {
        _refuse();
      }
      codeAnchor = context.selectedBuildRoot;
      support = p.join(
        codeAnchor,
        'native/libforesight_diagnostic_support.${context.macOS ? 'dylib' : 'so'}',
      );
      launcher = p.join(codeAnchor, 'native/foresight-diagnostic-launcher');
      if (context.workerMode == 'aot') {
        worker = context.host == DiagnosticHost.service
            ? context.executable
            : p.join(codeAnchor, 'application/foresight-service');
        _candidate(codeAnchor, worker, executable: true);
      } else {
        worker = context.dartExecutable;
        // The explicit pinned SDK executable is metadata-checked under its
        // own selected anchor; never find Dart through PATH or `dart run`.
        if (!_absolute(worker) ||
            worker != context.executable &&
                context.host == DiagnosticHost.service) {
          _refuse();
        }
        if (!_identity(context.dartSdkIdentity) ||
            worker != p.join(context.dartSdkRoot, 'bin/dart')) {
          _refuse();
        }
        _candidate(context.dartSdkRoot, worker, executable: true);
        _candidate(anchor, context.packageConfig);
        prefix.addAll([
          '--disable-dart-dev',
          '--packages=${context.packageConfig}',
        ]);
        final script = context.workerMode == 'kernel'
            ? context.kernelWorker
            : context.sourceWorker;
        if (context.workerMode == 'jit' &&
            script !=
                p.join(
                  anchor,
                  'packages/foresight_core/bin/diagnostic_storage_worker.dart',
                )) {
          _refuse();
        }
        _candidate(anchor, script);
        if (context.workerMode == 'jit') {
          final descriptor = base64Url.encode(
            utf8.encode(
              jsonEncode({
                'schema': 1,
                'anchor': anchor,
                'build': codeAnchor,
                'dart': worker,
                'packages': context.packageConfig,
                'source': script,
                'kernel': '',
                'mode': 'jit',
                'sdk': context.dartSdkRoot,
                'sdk_id': context.dartSdkIdentity,
              }),
            ),
          );
          prefix.addAll([
            '-DFORESIGHT_DIAGNOSTIC_NATIVE_ID=${context.nativeId}',
            '-DFORESIGHT_DIAGNOSTIC_BUILD_ID=${context.dartId}',
            '-DFORESIGHT_DIAGNOSTIC_CATALOG_ID=${context.catalogId}',
            '-DFORESIGHT_DIAGNOSTIC_SOURCE_DESCRIPTOR=$descriptor',
          ]);
        }
        prefix.add(script);
      }
    } else {
      if (context.workerMode != 'aot') _refuse();
      if (marker >= 0) {
        anchor = context.executable.substring(0, marker + 4);
        final contents = p.join(anchor, 'Contents');
        worker = p.join(
          contents,
          'Library/Services/Open Foresight Service.app/Contents/MacOS/foresight-service',
        );
        support = p.join(
          contents,
          'Resources/lib/libforesight_diagnostic_support.dylib',
        );
        launcher = p.join(
          contents,
          'Resources/bin/foresight-diagnostic-launcher',
        );
      } else {
        final directory = p.basename(p.dirname(context.executable));
        if (!const {'bin', 'app'}.contains(directory)) _refuse();
        anchor = p.dirname(p.dirname(context.executable));
        worker = p.join(anchor, 'bin/foresight-service');
        support = p.join(anchor, 'lib/libforesight_diagnostic_support.so');
        launcher = p.join(anchor, 'bin/foresight-diagnostic-launcher');
      }
      if (context.host == DiagnosticHost.service &&
          context.executable != worker) {
        _refuse();
      }
      _candidate(anchor, context.executable, executable: true);
      _candidate(anchor, worker, executable: true);
    }
    _candidate(codeAnchor ?? anchor, launcher, executable: true);
    _candidate(codeAnchor ?? anchor, support);
    return DiagnosticStartupSelection._(
      context,
      anchor,
      launcher,
      support,
      worker,
      prefix,
    );
  }

  DiagnosticStorageCommand command(int applicationPid) {
    if (applicationPid <= 1 || applicationPid > 0x7fffffff) _refuse();
    final arguments = [
      launcher,
      context.nativeId,
      '$applicationPid',
      worker,
      ...prefix,
      '--diagnostic-storage-worker',
      '$applicationPid',
      '--diagnostic-native-support',
      support,
    ];
    if (arguments.length > 16 ||
        arguments.any((s) => utf8.encode(s).length > 1024) ||
        arguments.fold<int>(0, (n, s) => n + utf8.encode(s).length + 1) >
            2048) {
      _refuse();
    }
    return DiagnosticStorageCommand(
      nativeId: context.nativeId,
      dartId: context.dartId,
      catalogId: context.catalogId,
      arguments: arguments,
    );
  }
}

({String anchor, String support}) _supportLocation(
  DiagnosticStartupContext context,
) {
  if (!_absolute(context.executable)) _refuse();
  final marker = context.executable.indexOf('.app/Contents/');
  if (_sourceSelected(context)) {
    final anchor = context.sourceAnchor;
    if (!_absolute(anchor) ||
        marker >= 0 && !p.isWithin(anchor, context.executable)) {
      _refuse();
    }
    return (
      anchor: context.selectedBuildRoot,
      support: p.join(
        context.selectedBuildRoot,
        'native/libforesight_diagnostic_support.${context.macOS ? 'dylib' : 'so'}',
      ),
    );
  }
  if (context.workerMode != 'aot') _refuse();
  if (marker >= 0) {
    final anchor = context.executable.substring(0, marker + 4);
    return (
      anchor: anchor,
      support: p.join(
        anchor,
        'Contents/Resources/lib/libforesight_diagnostic_support.dylib',
      ),
    );
  }
  if (!_linuxInstallationEntry(context.executable)) _refuse();
  final anchor = p.dirname(p.dirname(context.executable));
  return (
    anchor: anchor,
    support: p.join(anchor, 'lib/libforesight_diagnostic_support.so'),
  );
}

/// The only authority selected early is the trusted support image. Command
/// metadata is intentionally unresolved until the owner's first eligibility.
final class DiagnosticPreparedSupport {
  const DiagnosticPreparedSupport._(this.context, this.anchor, this.support);
  final DiagnosticStartupContext context;
  final String anchor, support;

  static DiagnosticPreparedSupport resolveEarly(
    DiagnosticStartupContext context,
  ) {
    if (!context.identitiesAvailable) _refuse();
    if (_sourceSelected(context) &&
        context.workerMode != 'aot' &&
        (!_absolute(context.dartSdkRoot) ||
            !_identity(context.dartSdkIdentity) ||
            context.dartExecutable != p.join(context.dartSdkRoot, 'bin/dart') ||
            !_absolute(context.packageConfig))) {
      _refuse();
    }
    final location = _supportLocation(context);
    _candidate(location.anchor, location.support);
    return DiagnosticPreparedSupport._(
      context,
      location.anchor,
      location.support,
    );
  }

  DiagnosticStorageCommand command(int applicationPid) {
    final selected = DiagnosticStartupSelection.resolve(context);
    if (selected.support != support) _refuse();
    return selected.command(applicationPid);
  }

  DiagnosticNativeFunctions loadEarly() =>
      DiagnosticNativeFunctions.fromImage(DynamicLibrary.open(support));
}

final class DiagnosticStartup {
  const DiagnosticStartup._(this.configuration, this.selection, this.functions);
  final DiagnosticConfiguration configuration;
  final DiagnosticPreparedSupport? selection;
  final DiagnosticNativeFunctions? functions;
  bool get available => selection != null && functions != null;

  /// Must be the composition root's first normal-startup operation. A child
  /// invocation has its separate validation path and never starts a logger.
  static DiagnosticStartup beforeApplication({
    required Map<String, String> environment,
    required DiagnosticStartupContext context,
  }) {
    final configuration = DiagnosticConfiguration.fromEnvironment(environment);
    if (!configuration.enabled || !context.identitiesAvailable) {
      return DiagnosticStartup._(configuration, null, null);
    }
    try {
      final selection = DiagnosticPreparedSupport.resolveEarly(context);
      return DiagnosticStartup._(
        configuration,
        selection,
        selection.loadEarly(),
      );
    } catch (_) {
      return DiagnosticStartup._(configuration, null, null);
    }
  }
}

/// The child executor receives only this already-loaded original system image
/// and closed build metadata. Its watcher must run before verifyBeforeHello.
final class DiagnosticChildStartup {
  const DiagnosticChildStartup._({
    required this.functions,
    required this.expectedParentPid,
    required this.nativeId,
    required this.dartId,
    required this.catalogId,
    required this.verifyBeforeHello,
  });
  final DiagnosticNativeFunctions functions;
  final int expectedParentPid;
  final String nativeId, dartId, catalogId;
  final Future<void> Function()? verifyBeforeHello;
}

DiagnosticChildStartup loadDiagnosticChildStartup(
  DiagnosticWorkerInvocation invocation, {
  DiagnosticHost host = DiagnosticHost.service,
}) {
  if (invocation.kind != DiagnosticWorkerInvocationKind.valid) _refuse();
  final context = DiagnosticStartupContext.current(host);
  if (!context.identitiesAvailable) _refuse();
  final location = _supportLocation(context);
  if (invocation.support != location.support) _refuse();
  // The sole pre-watch regular-file exception: trusted system DSO. Do not
  // resolve/check source, packages, kernels, launcher or profile at this point.
  _candidate(location.anchor, location.support);
  final functions = DiagnosticNativeFunctions.fromImage(
    DynamicLibrary.open(location.support),
  );
  return DiagnosticChildStartup._(
    functions: functions,
    expectedParentPid: invocation.parentPid!,
    nativeId: context.nativeId,
    dartId: context.dartId,
    catalogId: context.catalogId,
    verifyBeforeHello: context.workerMode == 'aot'
        ? null
        : () => verifyDiagnosticWorkerSources(
            image: functions.image!,
            sourceAnchor: context.sourceAnchor,
            buildRoot: context.selectedBuildRoot,
            sdkRoot: context.dartSdkRoot,
            sdkId: context.dartSdkIdentity,
            packageConfig: context.packageConfig,
            nativeId: context.nativeId,
            workerId: context.dartId,
            catalogId: context.catalogId,
            mode: context.workerMode,
          ),
  );
}
