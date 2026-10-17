import 'dart:async';
import 'dart:io';

import 'dedicated_query_runtime.dart';
import 'model_vault.dart';

const dedicatedEncryptedQueryBackend = 'legacy_query_cpu_encrypted';

typedef LeasedQueryRuntimeFactory =
    QueryCompletionRuntime Function(
      String python,
      String worker,
      String plaintextModel,
    );

class _EncryptedRequest {
  _EncryptedRequest(this.id);
  final String id;
  bool cancelled = false;
  bool delegated = false;
}

/// Holds one private plaintext lease for its owned worker. A startup cancellation
/// stops its own decryption helper; active inference cancellation is delegated
/// with the caller's request ID and retains the lease for the next request.
class EncryptedDedicatedQueryRuntime implements QueryCompletionRuntime {
  EncryptedDedicatedQueryRuntime({
    required this.python,
    required this.worker,
    required this.encryptedModel,
    required this.vaultRoot,
    MacModelVault Function(Directory)? vaultFactory,
    LeasedQueryRuntimeFactory? runtimeFactory,
  }) : _vaultFactory = vaultFactory ?? ((root) => MacModelVault(root: root)),
       _runtimeFactory =
           runtimeFactory ??
           ((python, worker, model) => DedicatedQueryRuntime(
             python: python,
             worker: worker,
             model: model,
           ));

  final String python, worker, encryptedModel;
  final Directory vaultRoot;
  final MacModelVault Function(Directory) _vaultFactory;
  final LeasedQueryRuntimeFactory _runtimeFactory;
  MacModelVault? _vault;
  ModelVaultLease? _lease;
  QueryCompletionRuntime? _runtime;
  Future<void>? _starting;
  Future<void>? _retiring;
  Future<void>? _closing;
  _EncryptedRequest? _active;
  bool _closed = false;
  int _epoch = 0;

  Future<void> _start() async {
    if (_runtime != null) return;
    final epoch = _epoch;
    final vault = _vaultFactory(vaultRoot);
    _vault = vault;
    ModelVaultLease? lease;
    try {
      lease = await vault.openLease(File(encryptedModel));
      if (_closed || epoch != _epoch) {
        throw StateError('Encrypted question detection cancelled');
      }
      final runtime = _runtimeFactory(python, worker, lease.path);
      _lease = lease;
      _runtime = runtime;
      lease = null;
    } catch (_) {
      await vault.close();
      await lease?.close();
      if (identical(_vault, vault)) _vault = null;
      rethrow;
    }
  }

  @override
  Future<String> complete(String prompt, String requestId) async {
    if (_closed) throw StateError('Encrypted question detector is closed');
    if (_active != null) {
      throw StateError('Encrypted question detector is busy');
    }
    final request = _active = _EncryptedRequest(requestId);
    try {
      await _retiring;
      await (_starting = _start());
      if (_closed || request.cancelled) {
        throw StateError('Encrypted question detection cancelled');
      }
      request.delegated = true;
      final result = await _runtime!.complete(prompt, requestId);
      if (_closed || request.cancelled) {
        throw StateError('Encrypted question detection cancelled');
      }
      return result;
    } finally {
      _starting = null;
      try {
        if (request.cancelled && !request.delegated) await _retire();
      } finally {
        if (identical(_active, request)) _active = null;
      }
    }
  }

  @override
  void cancel(String requestId) {
    final request = _active;
    if (request == null || request.id != requestId) return;
    request.cancelled = true;
    if (request.delegated) {
      _runtime?.cancel(requestId);
    } else {
      _epoch++;
      _vault?.close().ignore();
    }
  }

  Future<void> _retire() {
    return _retiring ??= () async {
      try {
        // The worker must finish using the plaintext before it is removed.
        await _runtime?.close();
        await _lease?.close();
        _runtime = null;
        _lease = null;
      } finally {
        _retiring = null;
      }
    }();
  }

  @override
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _epoch++;
    final stopping = _vault?.close();
    return _closing = () async {
      try {
        await stopping;
        try {
          await _starting;
        } catch (_) {
          // The request owner receives startup cancellation or helper failure.
        }
        await _retire();
        _vault = null;
      } catch (_) {
        // Keep the lease when worker shutdown fails. A subsequent close may
        // retry cleanup, but new inference stays permanently disabled.
        _closing = null;
        rethrow;
      }
    }();
  }
}
