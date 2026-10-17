import 'package:foresight_core/src/reference_note_enhancement.dart';
import 'package:foresight_core/src/reference_note_enhancement_chunking.dart';
import 'package:foresight_core/src/reference_note_enhancement_context.dart';
import 'package:test/test.dart';

List<String> words(int count) => List.generate(count, (index) => 'w$index');

void main() {
  test(
    'short transcripts preserve interior whitespace after outer trimming',
    () {
      expect(chunkNoteEnhancementTranscript(' \n First\tsecond \n third  '), [
        'First\tsecond \n third',
      ]);
      expect(chunkNoteEnhancementTranscript(' \t\n '), isEmpty);
    },
  );

  test('saved windows contain 300 words and overlap by 40 words', () {
    final chunks = chunkNoteEnhancementTranscript(words(301).join(' '));
    expect(chunks.map((text) => text.split(' ').length), [300, 41]);
    expect(chunks[1], startsWith('w260 '));
    expect(chunks[1], endsWith('w300'));
    expect(chunkNoteEnhancementTranscript(words(300).join('\t')), [
      words(300).join('\t'),
    ]);
  });

  test('live windows contain 120 words and overlap by 20 words', () {
    final chunks = chunkNoteEnhancementTranscript(
      words(121).join(' '),
      isLive: true,
    );
    expect(chunks.map((text) => text.split(' ').length), [120, 21]);
    expect(chunks[1], startsWith('w100 '));
  });

  for (final suffix in ['.', '?', '!', ';', '."', ".'", '.)']) {
    test(
      'prefers latest sentence ending $suffix within the backward search',
      () {
        final tokens = words(340)..[280] = 'boundary$suffix';
        final chunks = chunkNoteEnhancementTranscript(tokens.join(' '));
        expect(chunks.first.split(' ').length, 281);
        expect(chunks.first, endsWith('boundary$suffix'));
        expect(chunks[1], startsWith('w241 '));
      },
    );
  }

  test(
    'sentence search excludes earlier endings and double closing punctuation',
    () {
      final tokens = words(340)
        ..[250] = 'tooEarly.'
        ..[280] = 'twoClosers.)"';
      final chunks = chunkNoteEnhancementTranscript(tokens.join(' '));
      expect(chunks.first.split(' ').length, 300);
      expect(chunks[1], startsWith('w260 '));
    },
  );

  test(
    'only the latest 50 live chunks are retained after complete splitting',
    () {
      final chunks = chunkNoteEnhancementTranscript(
        words(6100).join(' '),
        isLive: true,
      );
      expect(chunks.length, 50);
      expect(chunks.first, startsWith('w1100 '));
      expect(chunks.last, endsWith('w6099'));
    },
  );

  test(
    'new-note batches precede existing-only batches without altering note order',
    () {
      final pending = [
        (originalIndex: 10, text: 'old'),
        (originalIndex: 20, text: 'new'),
        (originalIndex: 30, text: 'old'),
        (originalIndex: 40, text: 'old'),
      ];
      final batches = [
        [0, 2],
        [3, 1],
      ];
      prioritizeNoteEnhancementBatches(batches, pending, {
        10: '',
        30: 'old',
        40: 'old',
      });
      expect(batches, [
        [3, 1],
        [0, 2],
      ]);
    },
  );

  test(
    'existing empty enhancements still count as existing during batch priority',
    () {
      final batches = [
        [0],
        [1],
      ];
      prioritizeNoteEnhancementBatches(
        batches,
        [(originalIndex: 8, text: 'existing'), (originalIndex: 9, text: 'new')],
        {8: ''},
      );
      expect(batches, [
        [1],
        [0],
      ]);
    },
  );

  test(
    'meaningful-content filter removes only the recovered prefix characters',
    () {
      for (final text in ['', ' \t', '1. 2): -- ** •', '123']) {
        expect(
          hasMeaningfulNoteEnhancementContent(text),
          isFalse,
          reason: text,
        );
      }
      for (final text in ['1. Owner', '+', '?', '💡', '١']) {
        expect(hasMeaningfulNoteEnhancementContent(text), isTrue, reason: text);
      }
    },
  );

  test('fallback trims but preserves existing star/dash prefixes exactly', () {
    expect(toNoteEnhancementFallbackBullet(' -no-space '), '-no-space');
    expect(toNoteEnhancementFallbackBullet(' **Owner** '), '**Owner**');
    expect(toNoteEnhancementFallbackBullet(' + Note '), '* + Note');
    expect(toNoteEnhancementFallbackBullet(' note '), '* note');
    expect(toNoteEnhancementFallbackBullet('  '), '* ');
  });
}
