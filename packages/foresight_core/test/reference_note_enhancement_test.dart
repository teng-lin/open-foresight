import 'package:foresight_core/src/reference_note_enhancement.dart';
import 'package:test/test.dart';

void main() {
  test(
    'enhanceable scribbles require meaningful text outside enhanced lines',
    () {
      expect(hasEnhanceableNoteScribbles(' \n- \n123'), false);
      expect(
        hasEnhanceableNoteScribbles('# Heading\n- **Owner:** Mira\n💡 Topic'),
        false,
      );
      expect(
        hasEnhanceableNoteScribbles('- **Owner:** Mira\nMira draft'),
        true,
      );
      expect(hasEnhanceableNoteScribbles('- ordinary raw bullet'), true);
    },
  );

  test('prior map pairs by ordinal without semantic matching', () {
    expect(
      mapNoteEnhancementPriorBullets(
        notes: 'Budget\nSchedule',
        enhancedNotes: '- Schedule details\n- Budget details',
      ),
      {0: '- Schedule details', 1: '- Budget details'},
    );
  });

  test('prior map filters marker-only shorthand before pairing', () {
    expect(
      mapNoteEnhancementPriorBullets(
        notes: '\n 123 \n -- ** • \n first \n + \n third ',
        enhancedNotes: 'heading prose\n  * First \n- Second\n+ Third\n- Extra',
      ),
      {0: '* First', 1: '- Second', 2: '+ Third'},
    );
  });

  test('prior map uses shorter count and stops at enhanced topics heading', () {
    expect(
      mapNoteEnhancementPriorBullets(
        notes: 'one\ntwo\nthree',
        enhancedNotes:
            '- Only\n### Potential Important Topics Not In Notes\n- Topic',
      ),
      {0: '- Only'},
    );
    expect(
      mapNoteEnhancementPriorBullets(
        notes: 'only',
        enhancedNotes: '- One\n- Excess',
      ),
      {0: '- One'},
    );
  });

  test(
    'prior raw extraction retains topic headings unlike producer planning',
    () {
      expect(
        mapNoteEnhancementPriorBullets(
          notes: 'Potential Important Topics Not In Notes\n* raw topic',
          enhancedNotes: '- First\n- Second',
        ),
        {0: '- First', 1: '- Second'},
      );
    },
  );

  test(
    'prior map is empty for blank enhanced text or empty extracted lists',
    () {
      expect(
        mapNoteEnhancementPriorBullets(notes: 'raw', enhancedNotes: ' \t\n '),
        isEmpty,
      );
      expect(
        mapNoteEnhancementPriorBullets(
          notes: 'raw',
          enhancedNotes: 'plain prose',
        ),
        isEmpty,
      );
      expect(
        mapNoteEnhancementPriorBullets(
          notes: '123\n -- ',
          enhancedNotes: '- Enhanced',
        ),
        isEmpty,
      );
    },
  );

  test('preview removes lowercase markdown or generic boundary fences', () {
    expect(
      cleanNoteEnhancementPreviewOutput('  ```markdown\n* Kept\n```  '),
      '* Kept',
    );
    expect(cleanNoteEnhancementPreviewOutput('```\n* Kept\n```'), '* Kept');
    expect(cleanNoteEnhancementPreviewOutput('```markdown* Kept'), '* Kept');
    expect(cleanNoteEnhancementPreviewOutput('* Kept ```'), '* Kept');
    expect(cleanNoteEnhancementPreviewOutput('```'), '');
    expect(cleanNoteEnhancementPreviewOutput('```markdown'), '');
  });

  test(
    'preview fence detection is literal and removes just one boundary layer',
    () {
      expect(
        cleanNoteEnhancementPreviewOutput('```MARKDOWN\n* Kept\n```'),
        'MARKDOWN\n* Kept',
      );
      expect(
        cleanNoteEnhancementPreviewOutput('```json\n* Kept\n```'),
        'json\n* Kept',
      );
      expect(cleanNoteEnhancementPreviewOutput('```markdownExtra'), 'Extra');
      expect(
        cleanNoteEnhancementPreviewOutput('``````* Kept``````'),
        '```* Kept```',
      );
      expect(
        cleanNoteEnhancementPreviewOutput('* Interior ``` stays'),
        '* Interior ``` stays',
      );
      expect(cleanNoteEnhancementPreviewOutput('``partial'), '``partial');
    },
  );

  test(
    'preview cleans model output before removing fences without recleaning',
    () {
      expect(
        cleanNoteEnhancementPreviewOutput(
          '```markdown\n* Kept\n```</output>discard',
        ),
        '* Kept',
      );
      expect(
        cleanNoteEnhancementPreviewOutput('```markdown\n## Key Notes\n```'),
        '## Key Notes',
      );
      expect(cleanNoteEnhancementPreviewOutput('  ## Key Notes  '), '');
    },
  );

  test('final model cleanup preserves fences', () {
    expect(
      cleanNoteEnhancementModelOutput(
        '```markdown\n* Kept\n```</output>discard',
      ),
      '```markdown\n* Kept\n```',
    );
  });

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
