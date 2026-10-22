import 'package:foresight_core/desktop.dart';

Future<Set<String>> searchSourceIds(StoreReader reader, String query) async {
  final result = await reader.read(StoreReadQueries.sourceSearch(query));
  if (result.error != null) throw result.error!;
  return result.value!;
}

Future<OutputStats> localOutputStats(StoreReader reader, {int? nowMs}) async {
  final result = await reader.read(
    StoreReadQueries.outputStats(
      now: nowMs == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(nowMs),
    ),
  );
  if (result.error != null) throw result.error!;
  return result.value!;
}

Future<int> localOutputWords(StoreReader reader) async =>
    (await localOutputStats(reader)).words;
