import 'package:foresight_core/src/reference_note_edit_mapping.dart';
import 'package:test/test.dart';

void main() {
  test('success replaces ordinal mapping and full comparison snapshots', () {
    final state = ReferenceNoteEditMapping(
      accepted: {9: '- Old'},
      pairs: [(shorthand: 'old', enhanced: '- Old')],
      lastSuccessfulShorthand: ['old'],
      lastSuccessfulEnhanced: ['- Old'],
      staleIndices: {9},
    );
    state.captureSuccess(
      notes: '123\nfirst\nsecond\nthird',
      enhancedNotes:
          '- First\n- Second\n### Potential Important Topics Not In Notes\n- Topic',
    );
    expect(state.accepted, {0: '- First', 1: '- Second'});
    expect(state.pairs, [
      (shorthand: 'first', enhanced: '- First'),
      (shorthand: 'second', enhanced: '- Second'),
    ]);
    expect(state.lastSuccessfulShorthand, ['first', 'second', 'third']);
    expect(state.lastSuccessfulEnhanced, ['- First', '- Second']);
    expect(state.staleIndices, {9});
    state.updateStaleBullets(
      notes: 'first\nsecond\nthird',
      enhancedNotes: '- First\n- Second',
    );
    expect(state.staleIndices, isEmpty);
  });

  test(
    'fromNotes seeds ordinal pairs without claiming a successful generation',
    () {
      final state = ReferenceNoteEditMapping.fromNotes(
        notes: '123\nraw one\nraw two\nraw three',
        enhancedNotes: '- First\n- Second',
      );
      expect(state.accepted, {0: '- First', 1: '- Second'});
      expect(state.pairs, [
        (shorthand: 'raw one', enhanced: '- First'),
        (shorthand: 'raw two', enhanced: '- Second'),
      ]);
      expect(state.lastSuccessfulShorthand, isEmpty);
      expect(state.lastSuccessfulEnhanced, isEmpty);
      expect(state.staleIndices, isEmpty);
    },
  );

  test('clear discards all ephemeral mapping and comparison state', () {
    final state = ReferenceNoteEditMapping(
      accepted: {0: '- One'},
      pairs: [(shorthand: 'one', enhanced: '- One')],
      lastSuccessfulShorthand: ['one'],
      lastSuccessfulEnhanced: ['- One'],
      staleIndices: {0},
    );
    state.clear();
    expect(state.accepted, isEmpty);
    expect(state.pairs, isEmpty);
    expect(state.lastSuccessfulShorthand, isEmpty);
    expect(state.lastSuccessfulEnhanced, isEmpty);
    expect(state.staleIndices, isEmpty);
  });

  test('raw reorder consumes exact matches before normalized matches', () {
    final state = ReferenceNoteEditMapping(
      accepted: {0: '- Capital', 1: '- Lower'},
      pairs: [
        (shorthand: 'Alpha', enhanced: '- Capital'),
        (shorthand: 'alpha', enhanced: '- Lower'),
      ],
    );
    expect(
      state.syncShorthand(
        notes: 'alpha\n1. ALPHA',
        enhancedNotes: '- Capital\n- Lower',
      ),
      '- Lower\n\n- Capital',
    );
    expect(state.accepted, {0: '- Lower', 1: '- Capital'});
    expect(state.pairs, [
      (shorthand: 'alpha', enhanced: '- Lower'),
      (shorthand: '1. ALPHA', enhanced: '- Capital'),
    ]);
  });

  test(
    'duplicate matches consume first remaining occurrence in encounter order',
    () {
      final state = ReferenceNoteEditMapping(
        accepted: {0: '- Other'},
        pairs: [
          (shorthand: 'same', enhanced: '- First'),
          (shorthand: 'same', enhanced: '- Second'),
        ],
      );
      expect(
        state.syncShorthand(
          notes: 'same\nsame',
          enhancedNotes: '- First\n- Second',
        ),
        '- First\n\n- Second',
      );
      expect(state.accepted, {0: '- First', 1: '- Second'});
    },
  );

  test(
    'ordinal fallback does not consume a pair needed by a later exact match',
    () {
      final state = ReferenceNoteEditMapping(
        accepted: {0: '- A', 1: '- B'},
        pairs: [
          (shorthand: 'A', enhanced: '- A'),
          (shorthand: 'B', enhanced: '- B'),
        ],
      );
      expect(
        state.syncShorthand(notes: 'new\nA\nextra', enhancedNotes: '- A\n- B'),
        '- A\n\n- A',
      );
      expect(state.accepted, {0: '- A', 1: '- A'});
      expect(state.pairs, [
        (shorthand: 'new', enhanced: '- A'),
        (shorthand: 'A', enhanced: '- A'),
      ]);
    },
  );

  test(
    'unchanged accepted values leave old pair text and controller untouched',
    () {
      final state = ReferenceNoteEditMapping(
        accepted: {0: '- Owner'},
        pairs: [(shorthand: 'owner', enhanced: '- Owner')],
      );
      expect(
        state.syncShorthand(notes: '1. OWNER', enhancedNotes: ' - Owner '),
        isNull,
      );
      expect(state.pairs, [(shorthand: 'owner', enhanced: '- Owner')]);
    },
  );

  test(
    'changed map preserves topic tail from literal while removing heading prefix',
    () {
      final state = ReferenceNoteEditMapping(
        accepted: {0: '- A', 1: '- B'},
        pairs: [
          (shorthand: 'A', enhanced: '- A'),
          (shorthand: 'B', enhanced: '- B'),
        ],
      );
      expect(
        state.syncShorthand(
          notes: 'B',
          enhancedNotes:
              '- A\n- B\n### 💡 Potential Important Topics Not In Notes\n- Topic  ',
        ),
        '- B\n\nPotential Important Topics Not In Notes\n- Topic',
      );
    },
  );

  test(
    'raw-empty clears mapping and success snapshots only when pairs existed',
    () {
      final state = ReferenceNoteEditMapping(
        accepted: {0: '- A'},
        pairs: [(shorthand: 'A', enhanced: '- A')],
        lastSuccessfulShorthand: ['A'],
        lastSuccessfulEnhanced: ['- A'],
        staleIndices: {0},
      );
      expect(state.syncShorthand(notes: '123\n -- ', enhancedNotes: '- A'), '');
      expect(state.accepted, isEmpty);
      expect(state.pairs, isEmpty);
      expect(state.lastSuccessfulShorthand, isEmpty);
      expect(state.lastSuccessfulEnhanced, isEmpty);
      expect(state.staleIndices, {0});
      state.updateStaleBullets(notes: '', enhancedNotes: '');
      expect(state.staleIndices, isEmpty);
      final noPairs = ReferenceNoteEditMapping(accepted: {0: '- Retained'});
      expect(
        noPairs.syncShorthand(notes: '', enhancedNotes: '- Retained'),
        isNull,
      );
      expect(noPairs.accepted, {0: '- Retained'});
    },
  );

  test(
    'unchanged baseline positions restore accepted text and clear staleness',
    () {
      final state = ReferenceNoteEditMapping(
        lastSuccessfulShorthand: ['one', 'two'],
        lastSuccessfulEnhanced: ['- One', '- Two'],
        staleIndices: {0, 1},
      );
      state.updateStaleBullets(
        notes: 'one\ntwo',
        enhancedNotes: '- One\n- Two',
      );
      expect(state.accepted, {0: '- One', 1: '- Two'});
      expect(state.staleIndices, isEmpty);
    },
  );

  test(
    'edits to either raw or enhanced text invalidate only iterated positions',
    () {
      final state = ReferenceNoteEditMapping(
        accepted: {0: '- Old one', 1: '- Old two', 8: '- Outside iteration'},
        lastSuccessfulShorthand: ['one', 'two'],
        lastSuccessfulEnhanced: ['- One', '- Two'],
      );
      state.updateStaleBullets(
        notes: 'changed one\ntwo',
        enhancedNotes: '- One\n- User edited two',
      );
      expect(state.accepted, {8: '- Outside iteration'});
      expect(state.staleIndices, {0, 1});
      expect(state.lastSuccessfulShorthand, ['one', 'two']);
      expect(state.lastSuccessfulEnhanced, ['- One', '- Two']);
    },
  );

  test(
    'enhanced deletion leaves noniterated map keys while removing old stale keys',
    () {
      final state = ReferenceNoteEditMapping(
        accepted: {0: '- One', 1: '- Two'},
        lastSuccessfulShorthand: ['one', 'two'],
        lastSuccessfulEnhanced: ['- One', '- Two'],
        staleIndices: {1},
      );
      state.updateStaleBullets(notes: 'one\ntwo', enhancedNotes: '- One');
      expect(state.accepted, {0: '- One', 1: '- Two'});
      expect(state.staleIndices, isEmpty);
    },
  );

  test(
    'empty current and prior enhanced lists clear staleness without clearing map',
    () {
      final state = ReferenceNoteEditMapping(
        accepted: {3: '- Retained'},
        staleIndices: {3},
      );
      state.updateStaleBullets(notes: '', enhancedNotes: 'plain prose');
      expect(state.accepted, {3: '- Retained'});
      expect(state.staleIndices, isEmpty);
    },
  );

  test('new enhanced positions and missing raw positions become stale', () {
    final state = ReferenceNoteEditMapping(
      accepted: {0: '- Prior', 1: '- Prior two'},
      lastSuccessfulShorthand: ['one'],
      lastSuccessfulEnhanced: ['- One'],
    );
    state.updateStaleBullets(notes: '123\n -- ', enhancedNotes: '- One\n- New');
    expect(state.accepted, isEmpty);
    expect(state.staleIndices, {0, 1});
  });
}
