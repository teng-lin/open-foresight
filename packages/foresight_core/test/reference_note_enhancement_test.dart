import 'package:foresight_core/src/reference_note_enhancement.dart';
import 'package:test/test.dart';

void main() {
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
