import 'package:foresight_core/src/text_budget.dart';
import 'package:test/test.dart';

void main() {
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
