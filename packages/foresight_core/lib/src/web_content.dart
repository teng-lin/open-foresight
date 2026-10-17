import 'package:grpc/grpc.dart';

import 'generated/web_content.pbgrpc.dart';
import 'reference_text.dart';

export 'generated/web_content.pb.dart';

const referenceWebContentHost = 'odml.pa.googleapis.com';
const referenceWebSummaryModel = 'models/odml-gemini-v4p1xs-supernova-one-shot';

class WebsiteSummaryResult {
  const WebsiteSummaryResult({
    this.title = '',
    this.summary = '',
    this.content = '',
  });
  final String title;
  final String summary;
  final String content;
}

/// Recovered OdmlService web-content path. This uses a remote Foresight RPC;
/// the app's selected local chat model does not perform this summarization.
/// Distribution credentials are supplied internally, without user project UI.
class WebContentService {
  WebContentService({required String apiKey, ClientChannel? channel})
    : _ownsChannel = channel == null,
      _channel =
          channel ??
          ClientChannel(
            referenceWebContentHost,
            port: 443,
            options: const ChannelOptions(
              credentials: ChannelCredentials.secure(),
            ),
          ) {
    _client = ForesightServiceClient(
      _channel,
      options: CallOptions(metadata: {'X-Goog-Api-Key': apiKey}),
    );
  }

  final bool _ownsChannel;
  final ClientChannel _channel;
  late final ForesightServiceClient _client;
  final _requests = <ResponseFuture<FetchExternalWebsiteResponse>>{};
  bool _closed = false;

  Future<FetchExternalWebsiteResponse?> fetchWebContent(
    String url, {
    int maxWords = 100,
    int summaryTimeoutMillis = -1,
  }) async {
    if (_closed) throw StateError('Web content service is closed.');
    if (url.isEmpty) return null;
    final request = _client.fetchExternalWebsite(
      FetchExternalWebsiteRequest(
        url: url,
        useTrawler: false,
        summarizeContent: true,
        maxSummarizationWords: maxWords,
        modelId: referenceWebSummaryModel,
        summaryTimeoutMillis: summaryTimeoutMillis,
        maxInputTokens: 131072,
      ),
    );
    _requests.add(request);
    final FetchExternalWebsiteResponse response;
    try {
      response = await request;
    } finally {
      _requests.remove(request);
    }
    response.content = sanitizeReferenceUtf8(response.content);
    response.mimeType = 'text/html';
    if (response.title.isEmpty && response.content.isNotEmpty) {
      final content = response.content;
      response.title = content.substring(0, content.length.clamp(0, 60));
    }
    return response;
  }

  Future<WebsiteSummaryResult> summarizeWebContent(
    String url,
    int maxWords, {
    bool enableCandidateRanking = false,
    int candidateRankingCount = 3,
    int summaryTimeoutMillis = -1,
  }) async {
    if (_closed) throw StateError('Web content service is closed.');
    final count = enableCandidateRanking && candidateRankingCount > 1
        ? candidateRankingCount
        : 1;
    // Original _parallelizeTasks preserves task indices and converts failed
    // fetch tasks to null. The callback's separate five-second timeout still
    // propagates; it is applied around this entire operation by SearchCallbacks.
    final candidates = await Future.wait([
      for (var i = 0; i < count; i++)
        _fetchCandidate(url, maxWords, summaryTimeoutMillis),
    ]);
    var bestScore = -1.0;
    var best = const WebsiteSummaryResult();
    for (final candidate in candidates) {
      if (candidate == null) continue;
      final score = candidate.summaryConfidenceScore;
      if (score >= bestScore) {
        bestScore = score;
        best = WebsiteSummaryResult(
          title: candidate.title,
          summary: candidate.summary,
          content: candidate.content,
        );
      }
    }
    return best;
  }

  Future<FetchExternalWebsiteResponse?> _fetchCandidate(
    String url,
    int maxWords,
    int timeout,
  ) async {
    try {
      return await fetchWebContent(
        url,
        maxWords: maxWords,
        summaryTimeoutMillis: timeout,
      );
    } catch (_) {
      return null;
    }
  }

  /// Adapter for SearchCallbacks' summary provider.
  Future<String> summarizeSearchPage(String url, int maxWords) async =>
      (await summarizeWebContent(url, maxWords)).summary;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait([
      for (final request in _requests.toList()) request.cancel(),
    ]);
    if (_ownsChannel) await _channel.shutdown();
  }
}
