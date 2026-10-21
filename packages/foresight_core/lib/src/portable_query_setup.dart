import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'dedicated_query_runtime.dart';
import 'reference_query_detector.dart';
import 'rpc_error.dart';
import 'store.dart';

/// Cross-platform import of a user-selected dedicated raw-completion worker.
/// No publisher credential, encrypted model lease or general Chat fallback.
Future<void> configurePortableQuery(
  Store store,
  String model,
  String runtime,
  String digest, {
  bool Function()? current,
}) async {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
    throw ArgumentError('A lowercase model SHA-256 digest is required');
  }
  final worker = File(runtime), asset = File(model);
  if (!asset.existsSync() ||
      !worker.existsSync() ||
      (worker.statSync().mode & 0x49) == 0) {
    throw StateError(
      'Select a local model and executable raw-completion worker',
    );
  }
  final probe = DedicatedQueryRuntime(
    python: worker.absolute.path,
    worker: worker.absolute.path,
    model: asset.absolute.path,
    timeout: const Duration(seconds: 15),
  );
  void check() {
    if (!(current?.call() ?? true)) {
      throw RpcError(RpcErrorCode.cancelled, 'Detector setup cancelled');
    }
  }

  final monitor = Timer.periodic(const Duration(milliseconds: 20), (_) {
    if (!(current?.call() ?? true)) probe.cancel('portable-query-setup');
  });
  try {
    check();
    if ((await sha256.bind(asset.openRead()).first).toString() != digest) {
      throw StateError('Dedicated detector model checksum mismatch');
    }
    check();
    await probe.complete(referenceQueryPrompt(''), 'portable-query-setup');
    check();
    await store.register(
      dedicatedQueryModelKind,
      asset.absolute.path,
      worker.absolute.path,
      backend: portableQueryBackend,
      expectedDigest: digest,
      current: current,
    );
  } finally {
    monitor.cancel();
    await probe.close();
  }
}
