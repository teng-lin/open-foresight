import 'package:foresight_core/foresight_core.dart';
import 'package:test/test.dart';

Future<ReferenceChatMemory> memory(int count, {int memoTokens = 10}) =>
    ReferenceChatMemory.load(
      [
        for (var i = 0; i < count; i++)
          referenceTextMessage(i.isEven ? 'user' : 'assistant', 'Entry $i'),
      ],
      estimate: (message) async =>
          referenceHistoryText(message).startsWith(referenceMemoryPrefix)
          ? memoTokens
          : 10,
    );

void main() {
  test(
    'history retains recorded counts and estimates only missing entries',
    () async {
      final estimated = <String>[];
      final history = await ReferenceChatMemory.load(
        [
          referenceTextMessage('user', 'Old count'),
          referenceTextMessage('assistant', 'Missing count'),
        ],
        tokenCounts: [17, null],
        estimate: (message) async {
          estimated.add(referenceHistoryText(message));
          return 3;
        },
      );
      expect(estimated, ['Missing count']);
      expect(history.tokens, 20);
      expect(history.tokenCounts, [17, 3]);
      await expectLater(
        ReferenceChatMemory.load([
          referenceTextMessage('user', 'Question'),
        ], tokenCounts: []),
        throwsStateError,
      );
    },
  );
  test(
    'word fallback rounds, handles whitespace and estimates text parts separately',
    () async {
      for (final (text, tokens) in [
        ('', 0),
        (' ', 1),
        ('one', 1),
        ('one two', 3),
        ('one two three', 4),
        ('中文问题', 1),
      ]) {
        expect(
          await estimateReferenceHistoryTokens(
            referenceTextMessage('user', text),
          ),
          tokens,
        );
      }
      expect(
        await estimateReferenceHistoryTokens({
          'content': [
            {'type': 'text', 'text': 'one'},
            {'type': 'text', 'text': 'two'},
            {'type': 'text', 'text': 123},
          ],
        }),
        2,
      );
      expect(
        await estimateReferenceHistoryTokens({
          'content': [
            {'type': 'image'},
            {'type': 'audio'},
            {'type': 'unknown'},
          ],
        }),
        480,
      );
      expect(
        await estimateReferenceHistoryTokens(
          {
            'content': [
              {'type': 'image'},
              {'type': 'audio'},
            ],
          },
          imageTokens: 17,
          audioTokens: 9,
        ),
        26,
      );
      expect(
        await estimateReferenceHistoryTokens({
          'content': 'one',
          'role': 'assistant',
        }, tokenize: (_) async => 17),
        17,
      );
    },
  );

  test(
    'equal threshold does not compress; oldest half is counted in entries',
    () async {
      final history = await memory(6);
      await history.prune(
        incomingTokens: 0,
        tokenLimit: 110,
        summarize: (_) async => fail('60 <= floor(110*.55)'),
      );
      expect(history.messages, hasLength(6));
      String? prompt;
      await history.prune(
        incomingTokens: 15,
        tokenLimit: 100,
        summarize: (value) async {
          prompt = value;
          return 'Memo';
        },
      );
      expect(
        prompt,
        '$referenceMemoryInstructions$referenceMemoryHeading'
        'user: Entry 0\n---\nassistant: Entry 1\n---\nuser: Entry 2',
      );
      expect(history.messages.map(referenceHistoryText), [
        '${referenceMemoryPrefix}Memo',
        'Entry 3',
        'Entry 4',
        'Entry 5',
      ]);
      expect(history.tokens, 40);
    },
  );

  test(
    'empty and failed compression fall back to FIFO without pair alignment',
    () async {
      for (final throws in [false, true]) {
        final history = await memory(6);
        await history.prune(
          incomingTokens: 10,
          tokenLimit: 100,
          summarize: (_) async {
            if (throws) throw StateError('Compression failed');
            return '';
          },
        );
        expect(history.messages.map(referenceHistoryText), [
          'Entry 2',
          'Entry 3',
          'Entry 4',
          'Entry 5',
        ]);
      }
      final history = await memory(3);
      await history.prune(
        incomingTokens: 30,
        tokenLimit: 100,
        summarize: (_) async => fail('Half count <= 1'),
      );
      expect(history.messages.first['role'], 'assistant');
    },
  );

  test(
    'oversized memo can itself be evicted and oversized incoming input clears history',
    () async {
      final history = await memory(6, memoTokens: 80);
      await history.prune(
        incomingTokens: 10,
        tokenLimit: 100,
        summarize: (_) async => 'Large memo',
      );
      expect(history.messages.map(referenceHistoryText), [
        'Entry 3',
        'Entry 4',
        'Entry 5',
      ]);
      await history.prune(
        incomingTokens: 100,
        tokenLimit: 100,
        summarize: (_) async => fail('Only three entries'),
      );
      expect(history.messages, isEmpty);
    },
  );

  test('cancellation after compression does not replace history', () async {
    final history = await memory(6);
    await expectLater(
      history.prune(
        incomingTokens: 10,
        tokenLimit: 100,
        summarize: (_) async => 'Memo',
        checkCurrent: () => throw StateError('Cancelled'),
      ),
      throwsStateError,
    );
    expect(history.messages.map(referenceHistoryText), [
      for (var i = 0; i < 6; i++) 'Entry $i',
    ]);
  });
}
