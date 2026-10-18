import 'package:foresight_core/foresight_core.dart';
import 'package:test/test.dart';

void expectResolved(
  ResolvedChatCitations actual,
  ResolvedChatCitations expected,
) {
  expect(actual.text, expected.text);
  expect(actual.sourceIndices, expected.sourceIndices);
}

void main() {
  test('tool text truncation preserves emoji and CJK scalar boundaries', () {
    expect(truncateChatToolResult('甲🧪乙', 2), startsWith('甲🧪\n'));
    expect(truncateChatToolResult('甲🧪', 2), '甲🧪');
    expect(truncateChatToolResult('😀😀', 1).contains('�'), isFalse);
  });
  test(
    'chat search shares a source table and deduplicates exact title/URL pairs',
    () {
      final sources = ReferenceChatSources();
      expect(sources.add(('Local', 'note://local')), 1);
      final first = sources.formatSearch((
        results: ['A', 'B'],
        sources: [('A', 'https://a'), ('B', 'https://b')],
        error: '',
      ));
      final second = sources.formatSearch((
        results: ['B2', 'A2'],
        sources: [('B', 'https://b'), ('Renamed A', 'https://a')],
        error: '',
      ));
      expect(first, '[Source:2] A\n\n[Source:3] B\n\n');
      expect(second, '[Source:3] B2\n\n[Source:4] A2\n\n');
      expect(sources.values, [
        ('Local', 'note://local'),
        ('A', 'https://a'),
        ('B', 'https://b'),
        ('Renamed A', 'https://a'),
      ]);
    },
  );
  test(
    'chat callback truncates at 2000 UTF-16 units with the recovered suffix',
    () {
      final sources = ReferenceChatSources();
      final text = sources.formatSearch((
        results: ['x' * 2200, 'B'],
        sources: [('A', 'https://a'), ('B', 'https://b')],
        error: '',
      ));
      expect(
        text,
        '${'[Source:1] ${'x' * 2200}\n\n[Source:2] B\n\n'.substring(0, 2000)}\n... [Content Truncated due to length] ...',
      );
      expect(sources.values, hasLength(2));
      expect(truncateChatToolResult('x' * 2000, 2000), 'x' * 2000);
    },
  );
  test(
    'references compact by first mention and retain duplicates within a marker',
    () {
      expectResolved(
        resolveChatCitations(
          'A [Source:3,1,3,99] B [Source:1] C [Source:0]',
          3,
        ),
        (text: 'A [Source:1, 2, 1] B [Source:2] C', sourceIndices: [3, 1]),
      );
    },
  );
  test('case-insensitive broad marker syntax extracts numeric mentions', () {
    expectResolved(
      resolveChatCitations(
        'A\n [source 2abc1] [Source:9999999999999999999999999999] [Source] end',
        2,
      ),
      (text: 'A [Source:1, 2] [Source] end', sourceIndices: [2, 1]),
    );
  });
  test(
    'missing sources and invalid markers are removed with leading whitespace',
    () {
      expectResolved(resolveChatCitations('A\n\n [Source:1] B [Source:2]', 0), (
        text: 'A B',
        sourceIndices: <int>[],
      ));
      expectResolved(
        resolveChatCitations('A [Source:none] B [Source:0,-99]', 1),
        (text: 'A B', sourceIndices: <int>[]),
      );
      expectResolved(resolveChatCitations('No citations.', 3), (
        text: 'No citations.',
        sourceIndices: <int>[],
      ));
    },
  );
}
