import 'package:foresight_core/src/reference_note_enhancement_plan.dart';
import 'package:test/test.dart';

void main() {
  test('trims LF lines and removes only empty or marker-only content', () {
    final plan = planNoteEnhancement(
      notes: ' \n  1. Owner\r\n 123 \n -- ** • \n + \n ? \n note\tinside ',
    );
    expect(plan.originalNotes, ['1. Owner', '+', '?', 'note\tinside']);
    expect(plan.pendingNotes, [
      (originalIndex: 0, text: '1. Owner'),
      (originalIndex: 1, text: '+'),
      (originalIndex: 2, text: '?'),
      (originalIndex: 3, text: 'note\tinside'),
    ]);
    expect(plan.skippedNotes, isEmpty);
    expect(plan.initialEnhancedBody, isNull);
  });

  test(
    'topic stripping retains prose and non-star/dash bullets after heading',
    () {
      final plan = planNoteEnhancement(
        notes:
            'first\n### Potential Important Topics Not In Notes suffix\n'
            '*topic\n-topic\nprose\n+ topic\n• topic\nlast',
      );
      expect(plan.originalNotes, [
        'first',
        'prose',
        '+ topic',
        '• topic',
        'last',
      ]);
      expect(plan.pendingNotes.last, (originalIndex: 4, text: 'last'));
    },
  );

  test('topic heading matching is case-sensitive', () {
    final plan = planNoteEnhancement(
      notes: 'potential important topics not in notes\n* keep',
    );
    expect(plan.originalNotes, [
      'potential important topics not in notes',
      '* keep',
    ]);
  });

  test(
    'falls back to meaningful lines when topics stripping removes everything',
    () {
      final plan = planNoteEnhancement(
        notes: 'Potential Important Topics Not In Notes\n* topic\n- topic',
      );
      expect(plan.originalNotes, [
        'Potential Important Topics Not In Notes',
        '* topic',
        '- topic',
      ]);
    },
  );

  test(
    'default skips existing and recognized enhanced notes without mutating input',
    () {
      final prior = {0: 'prior replacement', 4: '', 99: 'out of range'};
      final plan = planNoteEnhancement(
        notes: 'raw\n* **Owner**: Alice\n# Heading\nnew\nlast',
        existingEnhancedBullets: prior,
      );
      expect(plan.pendingNotes, [(originalIndex: 3, text: 'new')]);
      expect(plan.skippedNotes, [
        'prior replacement',
        '* **Owner**: Alice',
        '# Heading',
        '',
      ]);
      expect(plan.acceptedEnhancements, {
        0: 'prior replacement',
        1: '* **Owner**: Alice',
        2: '# Heading',
        4: '',
        99: 'out of range',
      });
      expect(
        plan.initialEnhancedBody,
        'prior replacement\n\n* **Owner**: Alice\n\n# Heading\n\nnew',
      );
      expect(prior, {0: 'prior replacement', 4: '', 99: 'out of range'});
    },
  );

  test(
    'reenhancement includes prior entries and recognized enhanced notes',
    () {
      final plan = planNoteEnhancement(
        notes: 'raw\n* **Owner**: Alice\n# Heading',
        existingEnhancedBullets: {0: 'prior'},
        updateExistingWithTranscript: true,
      );
      expect(plan.pendingNotes, [
        (originalIndex: 0, text: 'raw'),
        (originalIndex: 1, text: '* **Owner**: Alice'),
        (originalIndex: 2, text: '# Heading'),
      ]);
      expect(plan.acceptedEnhancements, {0: 'prior'});
      expect(plan.skippedNotes, isEmpty);
    },
  );

  test('targets address filtered positions and override reenhancement', () {
    final plan = planNoteEnhancement(
      notes: '\n123\nfirst\n* **Second**: retained\nthird',
      existingEnhancedBullets: {0: 'prior first'},
      targetBulletIndices: {1, 99, -1},
      updateExistingWithTranscript: true,
    );
    expect(plan.pendingNotes, [
      (originalIndex: 1, text: '* **Second**: retained'),
    ]);
    expect(plan.skippedNotes, ['prior first', 'third']);
    expect(plan.acceptedEnhancements, {0: 'prior first', 2: 'third'});
  });

  test(
    'targeting prior note does not bypass the default existing-note skip',
    () {
      final plan = planNoteEnhancement(
        notes: 'first\nsecond',
        existingEnhancedBullets: {0: 'prior'},
        targetBulletIndices: {0},
      );
      expect(plan.pendingNotes, isEmpty);
      expect(plan.acceptedEnhancements, {0: 'prior', 1: 'second'});
    },
  );

  test(
    'empty target set preserves raw text without fallback bullet prefixes',
    () {
      final plan = planNoteEnhancement(
        notes: 'one\n+ two\nthree',
        targetBulletIndices: {},
      );
      expect(plan.pendingNotes, isEmpty);
      expect(plan.skippedNotes, ['one', '+ two', 'three']);
      expect(plan.acceptedEnhancements, {0: 'one', 1: '+ two', 2: 'three'});
      expect(plan.initialEnhancedBody, isNull);
    },
  );

  test(
    'empty meaningful input has no pending or initial prior-map snapshot',
    () {
      final plan = planNoteEnhancement(
        notes: '\n123\n -- ',
        existingEnhancedBullets: {4: 'prior'},
      );
      expect(plan.originalNotes, isEmpty);
      expect(plan.pendingNotes, isEmpty);
      expect(plan.skippedNotes, isEmpty);
      expect(plan.initialEnhancedBody, isNull);
    },
  );
}
