import 'package:foresight_core/desktop.dart';

Future<Set<String>> searchSourceIds(StoreReader reader, String query) async {
  final result = await reader.read(StoreReadQueries.sourceSearch(query));
  if (result.error != null) throw result.error!;
  return result.value!;
}
