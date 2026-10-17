import 'package:foresight_core/src/reference_note_enhancement.dart';
import 'package:test/test.dart';

void main() {
  test('accepts star/dash prefixes and normalizes bare bold bullets only', () {
    final result = parseNoteEnhancementBatchOutput(
      '  **Owner:** Mira \n*plain\n-no-space\n+ plus\n• bullet\nprose\n## Heading\n* \n---\n*-*',
      20,
    );
    expect(result.notes, ['* **Owner:** Mira', '*plain', '-no-space']);
    expect(result.missedTopics, isEmpty);
  });

  test(
    'caps accepted notes rather than input lines and does not merge continuations',
    () {
      expect(
        parseNoteEnhancementBatchOutput(
          'prose\n---\n- First\ncontinuation\n**Second**\n* Third',
          2,
        ).notes,
        ['- First', '* **Second**'],
      );
      expect(parseNoteEnhancementBatchOutput('- Hidden', 0).notes, isEmpty);
      expect(parseNoteEnhancementBatchOutput('- Hidden', -1).notes, isEmpty);
    },
  );

  test(
    'default topic handling stops before its heading and every later line',
    () {
      final result = parseNoteEnhancementBatchOutput(
        '- Kept\n### 💡 Potential Important Topics Not In Notes\n- Omitted',
        5,
      );
      expect(result.notes, ['- Kept']);
      expect(result.missedTopics, isEmpty);
    },
  );

  test(
    'enabled topics retain heading, prose, marker-only and excess bullet lines',
    () {
      final result = parseNoteEnhancementBatchOutput(
        '- Kept\n- Capped\n### 💡 Potential Important Topics Not In Notes\n prose \n***\n- Topic\n\n- More',
        1,
        parseMissedTopics: true,
      );
      expect(result.notes, ['- Kept']);
      expect(result.missedTopics, [
        '### 💡 Potential Important Topics Not In Notes',
        'prose',
        '***',
        '- Topic',
        '- More',
      ]);
    },
  );

  test('topic marker is a case-sensitive substring checked before note cap', () {
    final result = parseNoteEnhancementBatchOutput(
      '- potential important topics not in notes\ninline Potential Important Topics Not In Notes suffix\n* Topic',
      0,
      parseMissedTopics: true,
    );
    expect(result.notes, isEmpty);
    expect(result.missedTopics, [
      'inline Potential Important Topics Not In Notes suffix',
      '* Topic',
    ]);
    expect(
      parseNoteEnhancementBatchOutput(
        '- potential important topics not in notes\n- Kept',
        2,
      ).notes,
      ['- potential important topics not in notes', '- Kept'],
    );
  });
}
