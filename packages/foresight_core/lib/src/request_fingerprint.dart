import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Durable request-key identity. Keep this compatible with persisted v1 rows:
/// unknown fields count, null map entries do not, and 1 differs from 1.0.
String requestArgumentsDigest(Map<String, dynamic> args) {
  Object? canonical(Object? value) => switch (value) {
    Map() => {
      for (final key in value.keys.cast<String>().toList()..sort())
        if (value[key] != null) key: canonical(value[key]),
    },
    List() => [for (final item in value) canonical(item)],
    _ => value,
  };
  final fields = Map<String, dynamic>.of(args)
    ..removeWhere(
      (key, _) => const {
        'requestId',
        'conversation',
        'idempotency_key',
        'workspace_epoch',
      }.contains(key),
    );
  return sha256.convert(utf8.encode(jsonEncode(canonical(fields)))).toString();
}
