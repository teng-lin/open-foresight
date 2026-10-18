import 'dart:convert';
import 'package:test/test.dart';
import 'package:foresight_core/src/answer_contract.dart';

void main() {
  test(
    'validation failures count reasons without weakening citation grammar',
    () {
      final before = answerValidationFailures['citation_group'] ?? 0;
      expect(() => citationIds('[see S3 manual]', 3), throwsFormatException);
      expect(answerValidationFailures['citation_group'], before + 1);
      expect(() => GroundedAnswer.parse('{', {'S1'}), throwsFormatException);
      expect(answerValidationFailures['json'], greaterThan(0));
      expect(
        () => answerValidationFailures['forged'] = 4,
        throwsUnsupportedError,
      );
    },
  );

  test('all IDs in comma, space and inclusive ranges must be selected', () {
    for (final group in [
      'S1, S2',
      'S1 S2',
      'S1-S3',
      'S1–S3',
      'S1—3',
      'S1, S2-S3',
    ]) {
      final payload = jsonEncode({
        'answer': 'A fact [$group]',
        'citations': ['S1', 'S2', 'S3'],
      });
      final answer = GroundedAnswer.parse(payload, {'S1', 'S2', 'S3'});
      expect(answer.rendered, startsWith('A fact [$group]'));
      expect(answer.rendered, isNot(contains('[S2]')));
      expect(
        () => GroundedAnswer.parse(
          jsonEncode({
            'answer': 'A fact [$group]',
            'citations': ['S1'],
          }),
          {'S1', 'S2', 'S3'},
        ),
        throwsFormatException,
      );
    }
    for (final group in [
      'S1, S9',
      'S1 S9',
      'S1-S4',
      'S3-S1',
      'S1; S2',
      'S1.1',
      'S1-S99999999999999999999999999',
    ]) {
      expect(
        () => GroundedAnswer.parse(
          jsonEncode({
            'answer': 'A fact [$group]',
            'citations': ['S1', 'S2', 'S3'],
          }),
          {'S1', 'S2', 'S3'},
        ),
        throwsFormatException,
      );
    }
  });
  test('malformed JSON shapes consistently raise FormatException', () {
    for (final value in [
      null,
      1,
      [],
      {},
      {'answer': 42, 'citations': []},
      {'answer': 'x'},
      {'answer': 'x', 'citations': 'S1'},
      {
        'answer': 'x',
        'citations': [1],
      },
      {'answer': 'x', 'citations': null},
      {'answer': 'x', 'citations': [], 'status': 1},
      {'answer': 'x', 'citations': [], 'status': null},
    ]) {
      expect(
        () => GroundedAnswer.parse(jsonEncode(value), {'S1'}),
        throwsFormatException,
      );
    }
  });

  test(
    'citation payload determines status without a generated branch selector',
    () {
      expect(
        GroundedAnswer.parse('{"answer":"Friday","citations":["S1"]}', {
          'S1',
        }).sufficient,
        true,
      );
      expect(
        GroundedAnswer.parse('{"answer":"","citations":[]}', {'S1'}).rendered,
        'Insufficient context',
      );
    },
  );
  test(
    'insufficient status is canonicalized without publishing unsupported text',
    () {
      for (final text in [
        '',
        'No relevant evidence found',
        'An unsupported claim',
      ]) {
        final answer = GroundedAnswer.parse(
          '{"status":"insufficient_context","answer":"$text","citations":[]}',
          {'S1'},
        );
        expect(answer.rendered, 'Insufficient context');
        expect(answer.sufficient, false);
      }
      expect(
        () => GroundedAnswer.parse(
          '{"status":"insufficient_context","answer":"","citations":["S1"]}',
          {'S1'},
        ),
        throwsFormatException,
      );
    },
  );
  test('only model-selected supplied citations are rendered', () {
    final answer = GroundedAnswer.parse(
      '{"status":"answered","answer":"Alice owns the draft.","citations":["S2"]}',
      {'S1', 'S2'},
    );
    expect(answer.rendered, 'Alice owns the draft. [S2]');
    expect(answer.citations, ['S2']);
  });
  test('unknown, missing and contradictory inline citations are rejected', () {
    for (final response in [
      '{"status":"answered","answer":"A fact","citations":[]}',
      '{"status":"answered","answer":"A fact","citations":["S9"]}',
      '{"status":"answered","answer":"A fact [S2]","citations":["S1"]}',
    ]) {
      expect(
        () => GroundedAnswer.parse(response, {'S1', 'S2'}),
        throwsFormatException,
      );
    }
  });
  test(
    'insufficient context has no fabricated citation and partial JSON stays provisional',
    () {
      final answer = GroundedAnswer.parse(
        '{"status":"insufficient_context","answer":"Insufficient context","citations":[]}',
        {'S1'},
      );
      expect(answer.sufficient, false);
      expect(answer.citations, isEmpty);
      expect(
        provisionalAnswer('{"status":"answered","answer":"Alice owns'),
        'Alice owns',
      );
      expect(provisionalAnswer('{"status":"answered"'), isNull);
    },
  );
}
