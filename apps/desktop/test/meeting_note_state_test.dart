import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/features/meetings/meeting_note_state.dart';

void main() {
  bool reload(
    MeetingNoteSnapshot stored, {
    int? manual = 20,
    int? enhanced = 500,
    String body = 'Raw',
    String result = 'Enhanced',
    bool dirty = false,
    bool programmatic = false,
  }) => stored.shouldReload(
    currentBody: body,
    currentEnhanced: result,
    localManualEdit: manual,
    localEnhanced: enhanced,
    dirty: dirty,
    programmaticWrite: programmatic,
  );

  test(
    'stored enhanced and local manual dates take literal priority over newer alternatives',
    () {
      expect(
        reload(
          const MeetingNoteSnapshot(
            body: 'Raw',
            enhanced: 'Enhanced',
            lastEnhanced: 10,
            lastManualEdit: 1000,
            timestamp: 2000,
          ),
        ),
        isFalse,
      );
      expect(
        reload(
          const MeetingNoteSnapshot(
            body: 'Raw',
            enhanced: 'Enhanced',
            lastEnhanced: 30,
            lastManualEdit: 1,
            timestamp: 2,
          ),
        ),
        isTrue,
      );
      expect(
        reload(
          const MeetingNoteSnapshot(
            body: 'Raw',
            enhanced: 'Enhanced',
            lastEnhanced: 20,
            timestamp: 2000,
          ),
        ),
        isFalse,
      );
      expect(
        reload(
          const MeetingNoteSnapshot(
            body: 'Raw',
            enhanced: 'Enhanced',
            lastManualEdit: 30,
          ),
        ),
        isTrue,
      );
      expect(
        reload(
          const MeetingNoteSnapshot(
            body: 'Raw',
            enhanced: 'Enhanced',
            timestamp: 30,
          ),
        ),
        isTrue,
      );
      expect(
        reload(
          const MeetingNoteSnapshot(
            body: 'Raw',
            enhanced: 'Enhanced',
            timestamp: 30,
          ),
          manual: null,
          enhanced: 20,
        ),
        isTrue,
      );
      expect(
        reload(
          const MeetingNoteSnapshot(
            body: 'Raw',
            enhanced: 'Enhanced',
            timestamp: 30,
          ),
          manual: null,
          enhanced: null,
        ),
        isFalse,
      );
    },
  );

  test(
    'body differences and missing enhancement reload without inventing unknown dates',
    () {
      const stored = MeetingNoteSnapshot(body: 'Raw', enhanced: 'Enhanced');
      expect(reload(stored, body: 'Old raw'), isTrue);
      expect(reload(stored, result: 'Old enhanced'), isTrue);
      expect(reload(stored, result: ' \n '), isTrue);
      expect(reload(stored), isFalse);
      for (final dirty in [true, false]) {
        for (final programmatic in [true, false]) {
          if (!dirty && !programmatic) continue;
          expect(
            reload(
              stored,
              body: 'Old raw',
              result: '',
              dirty: dirty,
              programmatic: programmatic,
            ),
            isFalse,
          );
        }
      }
    },
  );
}
