import 'package:test/test.dart';
import 'package:foresight_core/src/answer_contract.dart';

void main() {
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
