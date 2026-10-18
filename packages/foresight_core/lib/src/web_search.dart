import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Public configuration recovered from the reference SearchService.
const referenceSearchEngineId = '67f1d2112dbb54ce4';
const referenceSearchTimeout = Duration(seconds: 5);

class WebSearchItem {
  const WebSearchItem({this.title, this.link, this.snippet});

  factory WebSearchItem.fromJson(Map<String, dynamic> json) => WebSearchItem(
    title: json['title'] as String?,
    link: json['link'] as String?,
    snippet: json['snippet'] as String?,
  );

  final String? title;
  final String? link;
  final String? snippet;
}

typedef SearchItems = Future<List<WebSearchItem>?> Function(String query);

/// The reference requests a summary of at most 100 words from its page service.
typedef SummarizeSearchPage = Future<String> Function(String url, int maxWords);

typedef WebSearchResult = ({
  List<String> results,
  List<(String, String)> sources,
  String error,
});

/// Tool-visible text from InferencePipeline's registered search callback.
/// Source numbers restart at one for each callback invocation.
String formatSearchToolResult(WebSearchResult result) {
  if (result.results.isEmpty) return result.error;
  final buffer = StringBuffer();
  for (var i = 0; i < result.sources.length; i++) {
    buffer.write('[Source:${i + 1}] ${result.results[i]}\n\n');
  }
  return buffer.toString();
}

/// Reproduces SearchCallbacks independently of the native summarizer backend.
class SearchCallbacks {
  SearchCallbacks({
    required SearchItems search,
    required SummarizeSearchPage summarize,
    this.timeout = referenceSearchTimeout,
  }) : _search = search,
       _summarize = summarize;

  final SearchItems _search;
  final SummarizeSearchPage _summarize;
  final Duration timeout;

  Future<WebSearchResult> handleGoogleSearch(Map<String, dynamic> args) async {
    final query = args['query'] as String?;
    if (query == null || query.isEmpty) {
      return (
        results: <String>[],
        sources: <(String, String)>[],
        error: 'Error: Search query was not provided.',
      );
    }
    final items = await _search(query);
    if (items == null || items.isEmpty) {
      return (
        results: <String>[],
        sources: <(String, String)>[],
        error: 'No results found.',
      );
    }
    final selected = items.take(3).toList();
    final summaries = <String, String>{};
    await Future.wait([
      for (final item in selected)
        if (item.link != null) _summarizeLink(item.link!, summaries),
    ]);
    final results = <String>[];
    final sources = <(String, String)>[];
    for (final item in selected) {
      final link = item.link;
      if (link == null) continue;
      final title = item.title ?? '';
      final summary = summaries[link] ?? '';
      sources.add((title, link));
      results.add(
        summary.isNotEmpty
            ? 'title: $title\nsummary: $summary'
            : 'title: $title\nsnippet: ${item.snippet ?? ''}',
      );
    }
    return (results: results, sources: sources, error: '');
  }

  Future<void> _summarizeLink(
    String link,
    Map<String, String> summaries,
  ) async {
    if (link.isEmpty) return;
    final summary = await _summarize(link, 100).timeout(timeout);
    if (summary.isNotEmpty) summaries[link] = summary;
  }
}

/// Search transport. Releases its per-request client even on timeout.
///
/// The original embeds a release credential. Callers supply a distribution
/// credential here; no reference credential is extracted or redistributed.
class SearchService {
  SearchService({
    required String apiKey,
    Uri? endpoint,
    this.timeout = referenceSearchTimeout,
  }) : _apiKey = apiKey,
       _endpoint =
           endpoint ??
           Uri.parse('https://customsearch.googleapis.com/customsearch/v1');

  final String _apiKey;
  final Uri _endpoint;
  final Duration timeout;

  Future<List<WebSearchItem>?> search(String query) async {
    if (_apiKey.isEmpty) {
      throw StateError('Search release credential is missing.');
    }
    final client = HttpClient();
    try {
      return await _request(client, query).timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<WebSearchItem>?> _request(HttpClient client, String query) async {
    final uri = _endpoint.replace(
      queryParameters: {
        ..._endpoint.queryParameters,
        'cx': referenceSearchEngineId,
        'num': '10',
        'q': query,
        'key': _apiKey,
      },
    );
    final request = await client.getUrl(uri);
    final response = await request.close();
    // Do not include the credential-bearing URI or response body in errors.
    if (response.statusCode != HttpStatus.ok) {
      throw SearchHttpException(response.statusCode);
    }
    final body = await utf8.decoder.bind(response).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final items = json['items'] as List<dynamic>?;
    return items
        ?.map((item) => WebSearchItem.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}

class SearchHttpException implements Exception {
  const SearchHttpException(this.statusCode);
  final int statusCode;

  @override
  String toString() => 'Search request failed (HTTP $statusCode).';
}
