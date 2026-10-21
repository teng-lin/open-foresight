import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:foresight_core/src/meeting_preparation.dart';
import 'package:test/test.dart';

void main() {
  test('frozen recovered prompts retain their exact UTF-8 identities', () {
    final fixtures =
        jsonDecode(
              File(
                'test/fixtures/meeting_ai_reference.json',
              ).readAsStringSync(),
            )
            as Map;
    for (final entry in fixtures.entries) {
      final text = entry.value['text'] as String;
      expect(
        sha256.convert(utf8.encode(text)).toString(),
        entry.value['sha256_utf8'],
        reason: 'PP${entry.key}',
      );
    }
    expect(documentMapPrefix, fixtures['24582']['text']);
    expect(documentReducePrefix, fixtures['24581']['text']);
    expect(fixtures['24724']['text'], contains('# Action Items'));
    expect(fixtures['24724']['text'], contains('high confidence'));
  });
}
