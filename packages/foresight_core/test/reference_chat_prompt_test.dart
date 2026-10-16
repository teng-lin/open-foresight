import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:intl/intl.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => Intl.defaultLocale = 'en_US');
  tearDown(() => Intl.defaultLocale = null);

  test('instructions match the recovered snapshot string byte for byte', () {
    expect(
      sha256.convert(utf8.encode(referenceChatInstructions)).toString(),
      '71a908bf5b041da7cff1c7ad1d397a62b2fc3d433774bad7dcaf26a351762f78',
    );
  });

  test('text query includes local date and optional knowledge before query', () {
    final date = DateTime(2026, 10, 16, 23, 59);
    expect(
      referenceChatPrompt('Question\nverbatim', now: date),
      '[Current Date: Friday, October 16, 2026]\n\nQuery: Question\nverbatim',
    );
    expect(
      referenceChatPrompt('Who?', context: '[Source:1] Mira', now: date),
      '[Current Date: Friday, October 16, 2026]\n\n'
      'Here is some context from the local knowledge base that might be relevant:\n'
      '[Source:1] Mira\nQuery: Who?',
    );
  });

  test('whole context truncates at 3000 UTF-16 units with original suffix', () {
    final context = '😀' * 1500;
    final exact = referenceChatPrompt('?', context: context);
    expect(exact, contains('$context\nQuery: ?'));
    expect(exact, isNot(contains('Content Truncated')));
    final longer = referenceChatPrompt('?', context: '${context}tail');
    expect(
      longer,
      contains('$context\n... [Content Truncated due to length] ...\nQuery: ?'),
    );
  });
}
