import 'package:foresight_core/src/reference_note_transcript_format.dart';
import 'package:test/test.dart';

void main() {
  test('empty speaker returns exact text without a delimiter', () {
    expect(
      formatNoteTranscriptSegment(speaker: '', text: '  words\t'),
      '  words\t',
    );
    expect(formatNoteTranscriptSegment(speaker: '', text: ''), '');
  });

  test('speaker and text whitespace remain unchanged in segment output', () {
    expect(
      formatNoteTranscriptSegment(speaker: ' Speaker ', text: '  words \n'),
      ' Speaker :   words \n',
    );
    expect(
      formatNoteTranscriptSegment(speaker: ' \t', text: 'word'),
      ' \t: word',
    );
  });

  test(
    'shared parent formatter retains blank text unlike filtered manager path',
    () {
      expect(
        formatNoteTranscriptSegment(speaker: 'Speaker', text: ' \t'),
        'Speaker:  \t',
      );
      expect(
        formatNoteTranscriptSegment(speaker: 'Speaker', text: ''),
        'Speaker: ',
      );
      expect(
        formatLiveNoteTranscript([
          (speaker: 'Speaker', text: ' \t'),
          (speaker: 'Speaker', text: ''),
        ]),
        '',
      );
    },
  );

  test(
    'live manager removes blank segments and joins retained originals with one LF',
    () {
      expect(
        formatLiveNoteTranscript([
          (speaker: 'Ignored', text: ' \n\t'),
          (speaker: ' A ', text: ' first '),
          (speaker: '', text: '  second\t'),
          (speaker: ' \t', text: 'third'),
          (speaker: '', text: ''),
        ]),
        ' A :  first \n  second\t\n \t: third',
      );
    },
  );

  test('empty iterable formats to empty text', () {
    expect(formatLiveNoteTranscript([]), '');
  });
}
