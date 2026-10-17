import 'package:foresight_core/src/reference_note_transcript_format.dart';
import 'package:test/test.dart';

void main() {
  test('structured schema, numeric duration and nullable defaults', () {
    final segments = parseStructuredTranscript(
      '[{"segment_title":"Planning",'
      '"duration_seconds":12.9,"turns":[{"speaker":" Ada ","text":"  words  "},'
      '{"speaker":"[Microphone]","text":"generic"},{}]},{}]',
    );
    expect(segments.first.durationSeconds, 12);
    expect(segments.last.title, 'Untitled Segment');
    expect(segments.last.turns, isEmpty);
    expect(segments.last.durationSeconds, isNull);
    expect(
      formatStructuredTranscriptToText(segments),
      '--- [Planning] ---\nAda:   words  \ngeneric\n\n\n'
      '--- [Untitled Segment] ---\n\n',
    );
  });
  test('legacy headings, CRLF, blank lines and first exact delimiter', () {
    final segments = parseStructuredTranscript(
      ' intro \r\n\n--- [ Topic ] ---\r\n'
      ' Ada: one: two \nNo:delimiter\n: anonymous\n--- [Empty] ---',
    );
    expect(segments.map((s) => s.title), ['Transcript', ' Topic ', 'Empty']);
    expect(segments[1].turns, [
      (speaker: 'Ada', text: 'one: two'),
      (speaker: 'Transcript', text: 'No:delimiter'),
      (speaker: '', text: 'anonymous'),
    ]);
    expect(segments.last.turns, isEmpty);
  });
  test('JSON and schema errors retry the whole legacy input', () {
    for (final raw in [
      '[broken',
      '[{"turns": {}}]',
      '[{"segment_title":7}]',
      '[{"duration_seconds":"12"}]',
      '[{"turns":[false]}]',
      '[{"turns":[{"speaker":7}]}]',
      '[{"turns":[{"text":false}]}]',
      '[{},null]',
    ]) {
      final segments = parseStructuredTranscript(raw);
      expect(segments.single.title, 'Transcript', reason: raw);
      expect(segments.single.turns, isNotEmpty, reason: raw);
    }
  });
  test(
    'empty list and saved extraction fallback preserve original records',
    () {
      expect(parseStructuredTranscript(''), isEmpty);
      expect(parseStructuredTranscript(' \n\t'), isEmpty);
      expect(parseStructuredTranscript('[]'), isEmpty);
      expect(extractSavedTranscriptText(' [] '), ' [] ');
      expect(extractSavedTranscriptText(' \n\t'), '');
      const legacy = '  --- [Legacy] ---\nMicrophone: spoken  ';
      expect(extractSavedTranscriptText(legacy), legacy);
      expect(extractSavedTranscriptText('{"other":1}'), '{"other":1}');
      expect(
        extractSavedTranscriptText('[{"turns":[{"text":"spoken"}]}]'),
        '--- [Untitled Segment] ---\nspoken\n\n',
      );
      expect(
        extractSavedTranscriptText('{"turns":[]}'),
        '--- [Transcript] ---\n{"turns":[]}\n\n',
      );
    },
  );
  test(
    'generic speaker decorations and case normalize without hiding names',
    () {
      for (final label in [
        '',
        '  ',
        '[MICROPHONE]',
        '((Remote))',
        '*Speaker*',
        'Unknown',
        'Transcript',
      ]) {
        expect(isGenericTranscriptSpeaker(label), isTrue, reason: label);
      }
      for (final label in ['Speaker 1', 'Ada', 'microphone 2', ' [remote] ']) {
        expect(isGenericTranscriptSpeaker(label), isFalse, reason: label);
      }
    },
  );
}
