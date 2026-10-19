import 'package:foresight_core/src/text_budget.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a named current source subject does not inherit an unrelated prior topic',
    () {
      const titles = [
        'Open Foresight Parity Audit - Project Juniper.txt',
        'Cedar Brief.txt',
      ];
      for (final question in [
        'Who owns Project Juniper, and when does it launch?',
        'Who owns project juniper, and when does it launch?',
      ]) {
        expect(
          isContextualFollowUp(question, sourceTitles: titles),
          isFalse,
          reason: question,
        );
      }
      expect(
        isContextualFollowUp('When does it launch?', sourceTitles: titles),
        isTrue,
      );
      expect(
        isContextualFollowUp('What about those dates?', sourceTitles: titles),
        isTrue,
      );
      expect(
        isContextualFollowUp(
          'Tell me more about Juniperous projects.',
          sourceTitles: titles,
        ),
        isTrue,
      );
    },
  );
  test('named sources preserve unresolved prior-turn references', () {
    const titles = ['Project Juniper.txt', 'The Project Plan.txt'];
    for (final question in [
      'How does Project Juniper compare with it?',
      'Does it launch before Project Juniper?',
      'Compare Project Juniper with Cedar Brief; when do they launch?',
      'Tell me more about the project.',
      'Who owns that Project Juniper?',
      'Does it own Project Juniper?',
      'Is Project Juniper similar to it?',
      'How does Project Juniper relate to it?',
      'Can Project Juniper replace it?',
    ]) {
      expect(
        isContextualFollowUp(question, sourceTitles: titles),
        isTrue,
        reason: question,
      );
    }
  });
  test('short CJK follow-up preserves context without spaces', () {
    expect(isContextualFollowUp('那它与之前的方法有什么区别？'), isTrue);
    expect(isContextualFollowUp('What about that?'), isTrue);
    expect(isContextualFollowUp('这' * 121), isFalse);
    expect(isContextualFollowUp('An independent new topic'), isFalse);
    for (final question in [
      '这家公司的收入是多少？',
      '那年发生了什么？',
      '他是一位科学家吗？',
      '再生能源有哪些？',
      '더위의 원인은 무엇인가요?',
    ]) {
      expect(isContextualFollowUp(question), isFalse, reason: question);
    }
    expect(isContextualFollowUp('더 자세히 설명해 주세요'), isTrue);
  });
  test('history truncation preserves supplementary Unicode scalars', () {
    expect(runePrefix('甲🧪乙', 2), '甲🧪');
    expect(runePrefix('甲🧪乙', 0), isEmpty);
  });
  test('proactive windows cap unspaced CJK and preserve emoji scalars', () {
    final window = proactiveTranscriptWindow('甲🧪' * 800, isFinal: true);
    expect(window.runes.length, 1000);
    expect(window, '甲🧪' * 500);
    expect(
      proactiveTranscriptWindow('那之前的方法现在还能继续使用吗', isFinal: false),
      '那之前的方法现在还能',
    );
  });
  test('web-chat identity uses source_uri with a document fallback', () {
    expect(
      sourceIdentity({'id': 'doc', 'source_uri': 'https://example.com/a'}),
      'https://example.com/a',
    );
    expect(sourceIdentity({'id': 'doc', 'source_uri': ''}), 'doc');
    expect(sourceIdentity({'id': 'doc'}), 'doc');
  });
}
