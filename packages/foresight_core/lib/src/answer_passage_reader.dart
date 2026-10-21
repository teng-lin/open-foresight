import 'dart:io';

import 'profile_paths.dart';
import 'rpc_error.dart';
import 'sqlite_store_reader.dart';
import 'store_read_queries.dart';

/// Compatibility entry point for non-service core callers. Service answers
/// borrow their writer's authoritative identity through their owned reader.
/// Both routes use the named worker projection and join actual SQL cleanup.
Future<List<Map<String, Object?>>> retrieveAnswerPassages(
  String databasePath,
  String question,
  Map<String, Object?> revisions,
  List<Map<String, Object?>> semantic,
) async {
  final reader = SqliteStoreReader.open(
    databasePath,
    profile: ProfilePaths(File(databasePath).parent.path, '').identity,
    connection: databasePath,
  );
  try {
    final result = await reader.read(
      StoreReadQueries.answerPassages(
        question,
        revisions,
        semantic,
        scope: 'standalone',
      ),
    );
    if (result.error != null) throw result.error!;
    return result.value ??
        (throw RpcError(RpcErrorCode.busy, 'Answer retrieval is busy; retry.'));
  } finally {
    await reader.close();
  }
}
