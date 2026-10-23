import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/src/web_search.dart';
import 'package:test/test.dart';

void main() {
  test('tool text numbers results with exact separators or returns error', () {
    expect(
      formatSearchToolResult((
        results: ['title: A\nsummary: Content', 'title: B\nsnippet: Text'],
        sources: [('A', 'one'), ('B', 'two')],
        error: '',
      )),
      '[Source:1] title: A\nsummary: Content\n\n[Source:2] title: B\nsnippet: Text\n\n',
    );
    expect(
      formatSearchToolResult((
        results: <String>[],
        sources: <(String, String)>[],
        error: 'No results found.',
      )),
      'No results found.',
    );
  });

  test('missing/empty query errors; whitespace is passed unchanged', () async {
    final queries = <String>[];
    final callbacks = SearchCallbacks(
      search: (q) async {
        queries.add(q);
        return null;
      },
      summarize: (_, _, {Duration? timeout}) async =>
          throw StateError('unexpected summary'),
    );
    for (final args in [
      <String, dynamic>{},
      {'query': ''},
    ]) {
      final result = await callbacks.handleGoogleSearch(args);
      expect(result.error, 'Error: Search query was not provided.');
      expect(result.results, isEmpty);
      expect(result.sources, isEmpty);
    }
    expect(
      (await callbacks.handleGoogleSearch({'query': '  '})).error,
      'No results found.',
    );
    expect(queries, ['  ']);
    await expectLater(
      callbacks.handleGoogleSearch({'query': 42}),
      throwsA(isA<TypeError>()),
    );
  });

  test(
    'concurrent summaries preserve rank order and exact fallback formatting',
    () async {
      final completions = <String, Completer<String>>{};
      final callbacks = SearchCallbacks(
        search: (_) async => [
          const WebSearchItem(title: 'First', link: 'one'),
          const WebSearchItem(
            title: 'Second',
            link: 'two',
            snippet: 'fallback',
          ),
          const WebSearchItem(link: 'three'),
          const WebSearchItem(link: 'ignored'),
        ],
        summarize: (url, budget, {Duration? timeout}) {
          expect(budget, 100);
          return (completions[url] = Completer<String>()).future;
        },
      );
      final pending = callbacks.handleGoogleSearch({'query': 'q'});
      await Future<void>.delayed(Duration.zero);
      expect(completions.keys, ['one', 'two', 'three']);
      completions['three']!.complete(' ');
      completions['two']!.complete('');
      completions['one']!.complete('summary');
      final result = await pending;
      expect(result.results, [
        'title: First\nsummary: summary',
        'title: Second\nsnippet: fallback',
        'title: \nsummary:  ',
      ]);
      expect(result.sources, [
        ('First', 'one'),
        ('Second', 'two'),
        ('', 'three'),
      ]);
      expect(result.error, '');
    },
  );

  test(
    'null links occupy rank; empty links remain sources without summary',
    () async {
      final callbacks = SearchCallbacks(
        search: (_) async => [
          const WebSearchItem(),
          const WebSearchItem(link: '', snippet: 'empty'),
          const WebSearchItem(),
          const WebSearchItem(link: 'fourth'),
        ],
        summarize: (_, _, {Duration? timeout}) async =>
            throw StateError('unexpected summary'),
      );
      final result = await callbacks.handleGoogleSearch({'query': 'q'});
      expect(result.sources, [('', '')]);
      expect(result.results, ['title: \nsnippet: empty']);
      expect(result.error, '');
    },
  );

  test(
    'duplicate URLs use last completed nonempty summary at both ranks',
    () async {
      final completions = <Completer<String>>[];
      final callbacks = SearchCallbacks(
        search: (_) async => [
          const WebSearchItem(title: 'A', link: 'same'),
          const WebSearchItem(title: 'B', link: 'same'),
        ],
        summarize: (_, _, {Duration? timeout}) {
          final c = Completer<String>();
          completions.add(c);
          return c.future;
        },
      );
      final pending = callbacks.handleGoogleSearch({'query': 'q'});
      await Future<void>.delayed(Duration.zero);
      expect(completions, hasLength(2));
      completions[1].complete('first');
      await Future<void>.delayed(Duration.zero);
      completions[0].complete('last');
      final result = await pending;
      expect(result.results, [
        'title: A\nsummary: last',
        'title: B\nsummary: last',
      ]);
      expect(result.sources, [('A', 'same'), ('B', 'same')]);
    },
  );

  test('summary error and deadline propagate', () async {
    for (final summarize in <SummarizeSearchPage>[
      (_, _, {Duration? timeout}) async => throw StateError('failure'),
      (_, _, {Duration? timeout}) => Completer<String>().future,
    ]) {
      final callbacks = SearchCallbacks(
        search: (_) async => [const WebSearchItem(link: 'one')],
        summarize: summarize,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        callbacks.handleGoogleSearch({'query': 'q'}),
        throwsA(anyOf(isA<StateError>(), isA<TimeoutException>())),
      );
    }
  });

  group('HTTP transport', () {
    late HttpServer server;
    late SearchService search;
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      search = SearchService(
        apiKey: 'fixture & key',
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/customsearch/v1'),
        timeout: referenceSearchTimeout,
      );
    });
    tearDown(() => server.close(force: true));
    test('GET carries exact parameters and decodes nullable items', () async {
      final handled = server.first.then((r) async {
        expect(r.method, 'GET');
        expect(r.uri.path, '/customsearch/v1');
        expect(r.uri.queryParameters, {
          'cx': '67f1d2112dbb54ce4',
          'num': '10',
          'q': '谁? + & café',
          'key': 'fixture & key',
        });
        r.response.write(
          jsonEncode({
            'items': [
              {
                'title': 'Title',
                'link': 'https://example.org',
                'snippet': 'Text',
              },
              {},
            ],
          }),
        );
        await r.response.close();
      });
      final items = await search.search('谁? + & café');
      await handled;
      expect(items, hasLength(2));
      expect(items!.first.title, 'Title');
      expect(items.first.link, 'https://example.org');
      expect(items.first.snippet, 'Text');
      expect(items.last.link, isNull);
    });
    test('missing items returns null', () async {
      final handled = server.first.then((r) async {
        r.response.write('{}');
        await r.response.close();
      });
      expect(await search.search('q'), isNull);
      await handled;
    });
    test('HTTP errors omit body and credential URI', () async {
      final handled = server.first.then((r) async {
        r.response.statusCode = 403;
        r.response.write('fixture & key');
        await r.response.close();
      });
      await expectLater(
        search.search('q'),
        throwsA(
          isA<SearchHttpException>()
              .having((e) => e.statusCode, 'status', 403)
              .having(
                (e) => e.toString(),
                'message',
                'Search request failed (HTTP 403).',
              ),
        ),
      );
      await handled;
    });
    test('malformed JSON fails', () async {
      final handled = server.first.then((r) async {
        r.response.write('{');
        await r.response.close();
      });
      await expectLater(search.search('q'), throwsFormatException);
      await handled;
    });
    test('deadline includes unfinished response body', () async {
      search = SearchService(
        apiKey: 'fixture',
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/customsearch/v1'),
        timeout: const Duration(milliseconds: 200),
      );

      final handled = server.first.then((r) async {
        r.response.write('{');
        await r.response.flush();
      });
      await expectLater(search.search('q'), throwsA(isA<TimeoutException>()));
      await handled;
    });
  });
}
