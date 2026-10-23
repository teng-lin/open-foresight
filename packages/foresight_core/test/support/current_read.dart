import 'package:foresight_core/desktop.dart';
import 'package:test/test.dart';

/// Contract assertions must observe current typed values, including nullable ones.
Future<T> currentRead<T>(StoreReader reader, ReadQuery<T> query) async {
  final result = await reader.read(query);
  expect(result.error, isNull, reason: query.projection);
  expect(result.current, isTrue, reason: query.projection);
  return result.value as T;
}
