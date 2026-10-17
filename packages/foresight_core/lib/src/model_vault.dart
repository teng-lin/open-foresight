import 'dart:async';
import 'dart:io';

import 'platform_services.dart';

class ModelVaultLease {
  ModelVaultLease._(this.path, this._directory);
  final String path;
  final Directory _directory;
  bool _closed = false;
  Future<void>? _closing;

  Future<void> close() async {
    if (_closed) return;
    final closing = _closing ??= _removeOwnedDirectory(_directory);
    try {
      await closing;
      _closed = true;
    } finally {
      if (identical(_closing, closing)) _closing = null;
    }
  }
}

/// Keeps encrypted model candidates in the profile and plaintext in owned,
/// private leases. The bundled helper uses this application's own Keychain key.
class MacModelVault {
  MacModelVault({
    required this.root,
    String? helperPath,
    Directory? tempRoot,
    Future<Process> Function(String, List<String>)? startProcess,
    this.helperTimeout = const Duration(minutes: 2),
  }) : _helper = helperPath ?? runtimeConfiguration['FORESIGHT_MODEL_CRYPTO'],
       _tempRoot = tempRoot ?? Directory.systemTemp,
       _startProcess =
           startProcess ??
           ((executable, arguments) => Process.start(executable, arguments));

  final Directory root;
  final String? _helper;
  final Directory _tempRoot;
  final Duration helperTimeout;
  final Future<Process> Function(String, List<String>) _startProcess;
  final _processes = <Process>{};
  final _operations = <Future<void>>{};
  bool _closed = false;
  Future<void>? _closing;

  Future<File> persist(
    File plaintext, {
    required String version,
    bool Function()? current,
  }) => _operation(() async {
    _checkCurrent(current);
    _checkInput(plaintext);
    _checkHelper();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(version)) {
      throw ArgumentError.value(version, 'version', 'Invalid model version');
    }
    privateDirectory(root.path);
    final directory = await createPrivateTempDirectory(root, 'model-$version-');
    try {
      final encrypted = File('${directory.path}/model.encrypted');
      await _run('encrypt', plaintext, encrypted);
      _checkOpen();
      _checkCurrent(current);
      _checkOutput(encrypted);
      return encrypted;
    } catch (_) {
      await _removeOwnedDirectory(directory);
      rethrow;
    }
  });

  Future<ModelVaultLease> openLease(File encrypted) => _operation(() async {
    _checkInput(encrypted);
    _checkHelper();
    // The root may be systemTemp itself; only the directory we create is owned.
    final directory = await createPrivateTempDirectory(
      _tempRoot,
      'foresight-model-lease-',
    );
    try {
      final plaintext = File('${directory.path}/model.plaintext');
      await _run('decrypt', encrypted, plaintext);
      _checkOpen();
      _checkOutput(plaintext);
      return ModelVaultLease._(plaintext.path, directory);
    } catch (_) {
      await _removeOwnedDirectory(directory);
      rethrow;
    }
  });

  Future<T> _operation<T>(Future<T> Function() body) async {
    _checkOpen();
    final completed = Completer<void>();
    _operations.add(completed.future);
    try {
      return await body();
    } finally {
      completed.complete();
      _operations.remove(completed.future);
    }
  }

  /// Stops and reaps only this vault's helpers. In-flight operations finish
  /// their owned-directory cleanup before close completes. Existing leases
  /// remain independently usable and must still be closed by their owners.
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    for (final process in _processes) {
      process.kill(ProcessSignal.sigkill);
    }
    return _closing = Future.wait(_operations.toList()).then((_) {});
  }

  void _checkOpen() {
    if (_closed) throw StateError('Model vault is closed.');
  }

  void _checkHelper() {
    if (_helper == null ||
        !File(_helper).existsSync() ||
        (File(_helper).statSync().mode & 0x49) == 0) {
      throw StateError('The bundled model encryption helper is unavailable.');
    }
  }

  Future<void> _run(String operation, File input, File output) async {
    _checkOpen();
    final process = await _startProcess(_helper!, [
      operation,
      '--input',
      input.absolute.path,
      '--output',
      output.absolute.path,
    ]);
    _processes.add(process);
    final drained = Future.wait([
      process.stdout.drain<void>(),
      process.stderr.drain<void>(),
    ]);
    try {
      if (_closed) process.kill(ProcessSignal.sigkill);
      int exit;
      try {
        exit = await process.exitCode.timeout(helperTimeout);
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await drained;
        throw StateError('Model $operation timed out.');
      }
      await drained;
      _checkOpen();
      if (exit != 0) throw StateError('Model $operation failed (exit $exit).');
    } finally {
      _processes.remove(process);
    }
  }

  static void _checkInput(File input) {
    if (FileSystemEntity.typeSync(input.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('The model input must be an existing regular file.');
    }
  }

  static void _checkOutput(File output) {
    if (FileSystemEntity.typeSync(output.path, followLinks: false) !=
            FileSystemEntityType.file ||
        output.lengthSync() == 0 ||
        (output.statSync().mode & 0x1ff) != 0x180) {
      throw StateError('The model helper did not create a private model file.');
    }
  }

  static void _checkCurrent(bool Function()? current) {
    if (current != null && !current())
      throw StateError('Model setup cancelled');
  }
}

Future<void> _removeOwnedDirectory(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    await Link(directory.path).delete();
  } else if (type == FileSystemEntityType.directory) {
    await directory.delete(recursive: true);
  }
}
