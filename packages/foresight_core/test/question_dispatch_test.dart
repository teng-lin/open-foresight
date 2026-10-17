import 'package:foresight_core/src/question_dispatch.dart';
import 'package:test/test.dart';

void main() {
  test(
    'prefix normalization removes punctuation while preserving Unicode words',
    () {
      expect(normalizeMeetingQuestion('  A-b!  C\nD '), 'ab c d');
      expect(normalizeMeetingQuestion('谁负责？ Café 😀 １２３'), '谁负责 café １２３');
      expect(normalizeMeetingQuestion('...'), '');
    },
  );

  test(
    'five-second duplicates refresh timestamps and allow the exact boundary',
    () {
      final filter = QuestionTextDeduplicator();
      expect(filter.process('[12:34:56] Who owns this?', 0), true);
      expect(filter.process('WHO OWNS THIS!', 4999), false);
      expect(filter.process('Who owns this?', 5000), false);
      expect(filter.process('Who owns this?', 10000), true);
      expect(filter.process('?', 10000), true);
      expect(filter.process('?', 10001), true);
    },
  );

  test('hash history survives unrelated input and wall-clock adjustments', () {
    final filter = QuestionTextDeduplicator();
    expect(filter.process('Who owns the draft?', 0), true);
    expect(filter.process('When is launch?', 10000), true);
    expect(filter.process('Who owns the draft?', 1), false);
  });

  test('prefix expiry is inclusive at exactly twenty seconds', () {
    final before = MeetingQuestionDispatcher();
    expect(before.process('Who owns the draft?', 0).accepted, true);
    expect(before.process('Who owns the draft?', 19999).accepted, false);
    final at = MeetingQuestionDispatcher();
    at.process('Who owns the draft?', 0);
    final result = at.process('Who owns the draft?', 20000);
    expect(result.accepted, true);
    expect(result.expired, ['who owns the draft']);
  });

  test(
    'equal prefix entries refresh twenty seconds after the five-second layer allows them',
    () {
      final filter = MeetingQuestionDispatcher();
      filter.process('Who owns the draft?', 0);
      expect(filter.process('Who owns the draft?', 5000).accepted, false);
      expect(filter.process('Who owns the draft?', 25000).accepted, true);
    },
  );

  test(
    'expanded prefixes replace while shorter revisions do not refresh the old entry',
    () {
      final filter = MeetingQuestionDispatcher();
      filter.process('Who?', 0);
      final expanded = filter.process('Who owns the draft?', 1);
      expect(expanded.accepted, true);
      expect(expanded.superseded, ['who']);
      expect(filter.process('Who owns?', 6000).accepted, false);
      final expired = filter.process('Who owns the draft?', 20001);
      expect(expired.accepted, true);
      expect(expired.expired, ['who owns the draft']);
    },
  );

  test('Jaccard matches at 0.7 when edit strategies do not match', () {
    final common = ['a', 'b', 'c', 'd', 'e', 'f', 'g'];
    final old = [
      ...common,
      'xxxxxxxxxxxxxxxxxxxx',
      'yyyyyyyyyyyyyyyyyyyy',
    ].join(' ');
    final next = [
      ...common,
      'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz',
    ].join(' ');
    final filter = MeetingQuestionDispatcher();
    filter.process(old, 0);
    expect(filter.process(next, 1).superseded, [old]);
    final below = MeetingQuestionDispatcher();
    below.process('$old qqqqqqqqqqqqqqqqqqqq', 0);
    expect(below.process(next, 1).superseded, isEmpty);
  });

  test(
    'token-set ratio matches at 0.8 without a prefix or partial-ratio match',
    () {
      final filter = MeetingQuestionDispatcher();
      filter.process('x abcdefgh', 0);
      expect(filter.process('abcdefgh y', 1).superseded, ['x abcdefgh']);
      final below = MeetingQuestionDispatcher();
      below.process('x abcdefg', 0);
      expect(below.process('abcdefg y', 1).superseded, isEmpty);
    },
  );

  test('partial ratio matches at 0.9 without matching token strategies', () {
    final filter = MeetingQuestionDispatcher();
    filter.process('abcd efghi', 0);
    expect(filter.process('xbcd efghi', 1).superseded, ['abcd efghi']);
    final below = MeetingQuestionDispatcher();
    below.process('abcd efghi', 0);
    expect(below.process('xxcd efghi', 1).superseded, isEmpty);
  });

  test(
    'copied filters isolate uncommitted changes and empty normalization does not prune',
    () {
      final filter = MeetingQuestionDispatcher();
      filter.process('Who?', 0);
      final copy = filter.copy();
      copy.process('Who owns the draft?', 1);
      expect(filter.process('Who owns?', 2).superseded, ['who']);
      expect(copy.process('Who owns?', 2).accepted, false);
      expect(copy.process('!!!', 30000).expired, isEmpty);
      expect(copy.process('Who owns the draft?', 30001).expired, [
        'who owns the draft',
      ]);
    },
  );
}
