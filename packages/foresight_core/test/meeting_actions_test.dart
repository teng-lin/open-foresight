import 'dart:convert';

import 'package:foresight_core/src/meeting_actions.dart';
import 'package:test/test.dart';

String response({
  String? owner = 'Alice',
  String? due = 'Friday',
  String quote = 'Alice will ship Friday.',
  String id = 'transcript:1',
  String state = 'open',
}) => jsonEncode({
  'tasks': [
    {
      'task': 'Ship release',
      'owner': owner,
      'due': due,
      'state': state,
      'evidence': [
        {'id': id, 'quote': quote},
      ],
    },
  ],
});

void main() {
  const source = MeetingEvidence('transcript:1', 'Alice will ship Friday.');
  test('extracts only evidence-backed owners and due expressions', () {
    final task = parseMeetingActions(response(), [source]).single;
    expect(task.owner, 'Alice');
    expect(task.due, 'Friday');
    expect(task.status, 'open');
    expect(
      parseMeetingActions(response(owner: null, due: null), [
        source,
      ]).single.owner,
      isNull,
    );
    for (final raw in [
      response(owner: 'Bob'),
      response(due: 'Monday'),
      response(id: 'invented'),
      response(quote: 'invented quotation'),
      response(state: 'maybe'),
    ]) {
      expect(() => parseMeetingActions(raw, [source]), throwsFormatException);
    }
    expect(
      () => parseMeetingActions(
        response(
          owner: 'Microphone',
          due: null,
          quote: 'Microphone will ship.',
        ),
        [const MeetingEvidence('transcript:1', 'Microphone will ship.')],
      ),
      throwsFormatException,
    );
    expect(parseMeetingActions('{"tasks":[]}', [source]), isEmpty);
  });
  test('bounded scalar-safe windows cover every input fragment', () {
    final text = List.generate(2000, (i) => '编号$i 中文😀 "quoted"\n').join();
    final windows = actionEvidenceWindows(
      [MeetingEvidence('transcript:1', text)],
      4096,
      768,
    );
    expect(windows.length, greaterThan(1));
    var covered = 0;
    for (final window in windows) {
      final piece = window.single.text;
      final start = text.indexOf(piece);
      expect(start, lessThanOrEqualTo(covered));
      covered = start + piece.length;
    }
    expect(covered, text.length);
    for (final window in windows) {
      final prompt = jsonEncode({
        'evidence': window.map((part) => part.json).toList(),
      });
      expect(
        utf8
                .encode(
                  '$workflowSourcePolicy$meetingActionsInstructions\n\n$prompt',
                )
                .length +
            768 +
            128,
        lessThanOrEqualTo(4096),
      );
    }
  });
  test('deduplicates commitments and accepts later cancellation', () async {
    var calls = 0;
    final tasks = await extractMeetingActions(
      evidence: [source, source],
      checkCurrent: () {},
      onProgress: (_) {},
      complete: (prompt, system, preview) async {
        expect(system, contains('untrusted source data'));
        return response(state: ++calls == 1 ? 'open' : 'cancelled');
      },
    );
    expect(tasks, hasLength(1));
    expect(tasks.single.status, 'cancelled');
  });
  test('cancellation prevents queued windows', () async {
    var current = true, calls = 0;
    await expectLater(
      extractMeetingActions(
        evidence: [source, source],
        checkCurrent: () {
          if (!current) throw StateError('cancelled');
        },
        onProgress: (_) {},
        complete: (_, __, ___) async {
          calls++;
          current = false;
          return response();
        },
      ),
      throwsStateError,
    );
    expect(calls, 1);
  });
}
