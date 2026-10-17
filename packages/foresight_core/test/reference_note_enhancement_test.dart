import 'package:foresight_core/src/reference_note_enhancement.dart';
import 'package:test/test.dart';

void main() {
  test('model output stops at earliest exact marker before trimming', () {
    expect(
      cleanNoteEnhancementModelOutput('  * Kept<eos>discard</output>'),
      '* Kept',
    );
    for (final marker in ['</output>', '<turn|>', '<eos>', '<end_of_turn>']) {
      expect(
        cleanNoteEnhancementModelOutput(' * Kept $marker discarded'),
        '* Kept',
      );
      expect(cleanNoteEnhancementModelOutput('$marker discarded'), '');
    }
    expect(cleanNoteEnhancementModelOutput('  <EOS>literal  '), '<EOS>literal');
  });

  test(
    'Key Notes cleanup retains the original case and whole-response scope',
    () {
      expect(cleanNoteEnhancementModelOutput('  ### Key Notes  '), '');
      expect(cleanNoteEnhancementModelOutput('## KeyNotes'), '');
      expect(cleanNoteEnhancementModelOutput('## key notes'), '## key notes');
      expect(
        cleanNoteEnhancementModelOutput('## Key Notes\n* Kept'),
        '## Key Notes\n* Kept',
      );
      expect(
        cleanNoteEnhancementModelOutput('* Kept\n## Key Notes'),
        '* Kept\n## Key Notes',
      );
    },
  );

  test('status messages match whole snapshots exactly', () {
    expect(isNoteEnhancementStatus('Evaluating notes...'), isTrue);
    expect(isNoteEnhancementStatus('Scanning the transcripts...'), isTrue);
    expect(isNoteEnhancementStatus('Structuring notes...'), isTrue);
    expect(isNoteEnhancementStatus(' Evaluating notes...'), isFalse);
    expect(
      isNoteEnhancementStatus('Evaluating notes... additional text'),
      isFalse,
    );
  });

  test('extraction stops at literal topics marker before heading filtering', () {
    expect(
      extractEnhancedNoteBullets(
        '  - First\r\n\n# Potential Important Topics Not In Notes\n- Excluded',
      ),
      ['- First'],
    );
    expect(
      extractEnhancedNoteBullets(
        '- First\n- Potential Important Topics Not In Notes\n- Excluded',
      ),
      ['- First'],
    );
    expect(
      extractEnhancedNoteBullets(
        '- First\n- potential important topics not in notes\n- Last',
      ),
      ['- First', '- potential important topics not in notes', '- Last'],
    );
  });
  test('formats trimmed nonempty notes with exactly two newlines', () {
    expect(
      formatEnhancedNotesWithSpacing(['  - One  ', '', '\t', ' 💡 Two\n']),
      '- One\n\n💡 Two',
    );
    expect(formatEnhancedNotesWithSpacing([]), '');
  });

  test('recognizes original enhancement prefixes and bold bullet pattern', () {
    for (final line in [
      ' ### 💡 Heading ',
      '💡 Detail',
      '## Heading',
      '# Heading',
      '* **Owner**: Mira',
      '-\t**Owner** Mira',
    ]) {
      expect(isAlreadyEnhancedNoteLine(line), isTrue, reason: line);
    }
    for (final line in [
      'Plain prose',
      '- Simple bullet',
      '### Plain heading',
      '**Owner**: Mira',
      'idea',
    ]) {
      expect(isAlreadyEnhancedNoteLine(line), isFalse, reason: line);
    }
  });

  test(
    'extracts original bullet prefixes and recognized enhancement lines',
    () {
      expect(
        extractEnhancedNoteBulletsFromLines([
          '  # Heading',
          '## Heading',
          '### 💡 Heading',
          ' Plain prose ',
          '',
          ' * One ',
          '- Two',
          '+ Three',
          ' • Four ',
          ' 💡 Five ',
          '-\t**Owner**: Mira',
          'Another plain line',
          '* Last',
        ]),
        [
          '* One',
          '- Two',
          '+ Three',
          '• Four',
          '💡 Five',
          '-\t**Owner**: Mira',
          '* Last',
        ],
      );
    },
  );

  test('removes complete indexed markers and case-insensitive line tags', () {
    expect(
      cleanNoteEnhancementTags(
        '<L:1:2>Plan</L:1>\n<LINE id="12">Review</LINE>\nNext',
      ),
      'Plan\nReviewNext',
    );
    expect(cleanNoteEnhancementTags('L:7>One 12:3>Two'), 'OneTwo');
  });

  test('retains unrelated markup and whitespace without trimming', () {
    expect(
      cleanNoteEnhancementTags('  <em>中文 notes</em>\n\n  '),
      '  <em>中文 notes</em>\n\n  ',
    );
    expect(cleanNoteEnhancementTags('before < L : after'), 'before after');
    expect(cleanNoteEnhancementTags('before </ L : 12'), 'before ');
  });

  test('marker cleanup is ordered and does not repair partial indices', () {
    expect(cleanNoteEnhancementTags('<L:3'), '3');
    expect(cleanNoteEnhancementTags('<L:3>Complete</L'), 'Complete');
  });
}
