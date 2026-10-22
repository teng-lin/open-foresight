import 'dart:convert';

import 'package:foresight_core/src/meeting_actions.dart';
import 'package:test/test.dart';

void main() {
  test(
    'artifact JSON retains grounded fields and stable normalized identity distinguishes owners',
    () async {
      const sources = [
        MeetingEvidence('source:1', 'Alice will ship the release Friday.'),
        MeetingEvidence('source:2', 'Bob will ship the release Friday.'),
        MeetingEvidence(
          'source:3',
          'Alice cancelled shipping the release Friday.',
        ),
      ];
      var calls = 0;
      final actions = await extractMeetingActions(
        evidence: sources,
        checkCurrent: () {},
        onProgress: (_) {},
        complete: (prompt, system, _) async {
          calls++;
          expect(system, contains('untrusted source data'));
          expect(
            (jsonDecode(prompt) as Map)['evidence'],
            sources.map((s) => s.json).toList(),
          );
          return jsonEncode({
            'tasks': [
              for (var i = 0; i < sources.length; i++)
                {
                  'task': i == 2 ? 'SHIP—the RELEASE!!!' : 'Ship the release',
                  'owner': i == 1 ? 'Bob' : 'Alice',
                  'due': 'Friday',
                  'state': i == 2 ? 'cancelled' : 'open',
                  'evidence': [
                    {'id': sources[i].id, 'quote': sources[i].text},
                  ],
                },
            ],
          });
        },
      );
      expect(calls, 1);
      expect(actions, hasLength(2));
      final artifacts = actions
          .map((action) => jsonDecode(jsonEncode(action.json)) as Map)
          .toList();
      expect(artifacts.map((row) => row['key']).toSet(), hasLength(2));
      final alice = artifacts.singleWhere((row) => row['owner'] == 'Alice');
      expect(alice, {
        'key': actions.singleWhere((a) => a.owner == 'Alice').key,
        'task': 'SHIP—the RELEASE!!!',
        'owner': 'Alice',
        'due': 'Friday',
        'status': 'cancelled',
        'evidence': [
          {'id': 'source:3', 'quote': sources[2].text},
        ],
      });
      expect(
        artifacts.singleWhere((row) => row['owner'] == 'Bob')['status'],
        'open',
      );
      final original = parseMeetingActions(
        jsonEncode({
          'tasks': [
            {
              'task': ' ship the release ',
              'owner': 'Alice',
              'due': 'Friday',
              'state': 'open',
              'evidence': [
                {'id': sources[0].id, 'quote': sources[0].text},
              ],
            },
          ],
        }),
        sources,
      ).single;
      expect(alice['key'], original.key);
      expect(
        renderMeetingActions(artifacts.cast<Map<String, Object?>>()),
        contains('— Cancelled'),
      );
    },
  );

  test(
    'tiny context and oversized evidence identifiers refuse before model work',
    () async {
      expect(
        () => actionEvidenceWindows(
          [const MeetingEvidence('id', 'Alice will ship.')],
          512,
          128,
        ),
        throwsStateError,
      );
      var calls = 0;
      await expectLater(
        extractMeetingActions(
          evidence: [MeetingEvidence('id' * 2000, 'Alice will ship.')],
          context: 2048,
          output: 128,
          checkCurrent: () {},
          onProgress: (_) {},
          complete: (_, __, ___) async {
            calls++;
            return '{"tasks":[]}';
          },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('identifier'),
          ),
        ),
      );
      expect(calls, 0);
    },
  );

  test(
    'narrow Unicode windows trim overlap while preserving every grounded fragment',
    () {
      final source = MeetingEvidence(
        'long-source',
        List.generate(150, (i) => '任务$i😀"\\\n').join(),
      );
      final overhead =
          utf8
              .encode(
                '$workflowSourcePolicy$meetingActionsInstructions\n\n{"evidence":[]}',
              )
              .length +
          128 +
          128;
      final context = overhead + 128;
      final windows = actionEvidenceWindows([source], context, 128);
      expect(windows.length, greaterThan(3));
      var covered = 0;
      for (final window in windows) {
        expect(window, hasLength(1));
        final fragment = window.single;
        expect(fragment.id, source.id);
        final start = source.text.indexOf(fragment.text);
        expect(start, greaterThanOrEqualTo(0));
        expect(start, lessThanOrEqualTo(covered));
        covered = start + fragment.text.length;
        expect(utf8.decode(utf8.encode(fragment.text)), fragment.text);
        final prompt = jsonEncode({
          'evidence': window.map((entry) => entry.json).toList(),
        });
        expect(
          utf8
                  .encode(
                    '$workflowSourcePolicy$meetingActionsInstructions\n\n$prompt',
                  )
                  .length +
              128 +
              128,
          lessThanOrEqualTo(context),
        );
      }
      expect(covered, source.text.length);
    },
  );
}
