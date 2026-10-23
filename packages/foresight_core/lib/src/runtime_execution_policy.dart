import 'dart:io';

import 'platform_services.dart';
import 'profile_paths.dart';
import 'rpc_error.dart';

String canonicalRuntimePath(String path) =>
    FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound
    ? canonicalProfilePath(path)
    : File(path).resolveSymbolicLinksSync();

/// Packaged executable selection belongs to the installation. Model data may
/// live in the profile; executable files and Python workers may not escape the
/// installed root through registration, stored settings or symbolic links.
String requireInstalledRuntime(String runtime) {
  final root = configuredInstallationRoot;
  if (root == null || runtime.isEmpty) return runtime;
  final selected = canonicalRuntimePath(runtime);
  if (!selected.startsWith('$root/')) {
    throw RpcError(
      RpcErrorCode.denied,
      'Runtime is outside this installation. Choose the bundled runtime in '
      'model settings before retrying: $runtime',
    );
  }
  return selected;
}
