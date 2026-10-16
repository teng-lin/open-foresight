import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';

import 'generated/web_content.pbgrpc.dart';
import 'web_content.dart' show referenceWebContentHost;

export 'generated/web_content.pb.dart'
    show ForesightSharedConfig, GetSharedConfigRequest, OnDeviceModelMetadata;

const referenceQueryDetectorModelType = 4;
const referenceClosestLowerFallback = 1;

/// Public metadata RPC recovered from the original OdmlService.
/// The credential comes from the same distribution configuration as web content.
class ModelConfigService {
  ModelConfigService({required String apiKey, ClientChannel? channel})
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
  bool _closed = false;

  Future<ForesightSharedConfig> fetch({required String appVersion}) {
    if (_closed) throw StateError('Model configuration service is closed.');
    if (appVersion.isEmpty) throw ArgumentError.value(appVersion, 'appVersion');
    return _client.getSharedConfig(
      GetSharedConfigRequest(
        appVersion: appVersion,
        platform: 'macos',
        fallbackMode: referenceClosestLowerFallback,
      ),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_ownsChannel) await _channel.shutdown();
  }
}

class NonRetryableModelDownloadException implements Exception {
  const NonRetryableModelDownloadException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'Model download failed: $message';
}

/// Does not retain the original exception or URI: HTTP errors can embed the
/// complete authenticated URL, including the distribution credential.
class ModelTransportException implements Exception {
  const ModelTransportException(this.failureType);
  final String failureType;
  @override
  String toString() => 'Model transport failed ($failureType).';
}

class ModelDownloadRetryPolicy {
  const ModelDownloadRetryPolicy({
    required this.maxAttempts,
    required this.delay,
  });

  /// Original PP13087: five attempts, 500 ms factor, 10 s cap, 25% jitter.
  factory ModelDownloadRetryPolicy.reference({Random? random}) {
    final source = random ?? Random();
    return ModelDownloadRetryPolicy(
      maxAttempts: 5,
      delay: (attempt) {
        if (attempt <= 0) return Duration.zero;
        final jitter = (source.nextDouble() * 2 - 1) * .25 + 1;
        // Preserve the two Duration multiplications and their separate rounding.
        final exponential =
            const Duration(milliseconds: 500) * pow(2, min(attempt, 31));
        final delay = exponential * jitter;
        const cap = Duration(seconds: 10);
        return delay >= cap ? cap : delay;
      },
    );
  }
  final int maxAttempts;
  final Duration Function(int failedAttempt) delay;
}

/// Inclusive parallel ranges and resume cursors follow original ChunkDownloader.
/// This returns transport bytes; authentication and atomic registration happen
/// separately, before replacing an installed model.
class ModelBlobDownloader {
  ModelBlobDownloader({
    required String apiKey,
    required this.parallelCount,
    ModelDownloadRetryPolicy? retryPolicy,
    HttpClient? client,
    Uri? origin,
    Future<void> Function(Duration)? sleep,
  }) : retryPolicy = retryPolicy ?? ModelDownloadRetryPolicy.reference(),
       _apiKey = apiKey,
       _client = client ?? HttpClient(),
       _ownsClient = client == null,
       _origin = origin ?? Uri.https(referenceWebContentHost),
       _sleep = sleep ?? Future<void>.delayed {
    if (parallelCount <= 0)
      throw ArgumentError.value(parallelCount, 'parallelCount');
    if (this.retryPolicy.maxAttempts <= 0) {
      throw ArgumentError.value(this.retryPolicy.maxAttempts, 'maxAttempts');
    }
  }

  final String _apiKey;
  final int parallelCount;
  final ModelDownloadRetryPolicy retryPolicy;
  final HttpClient _client;
  final bool _ownsClient;
  final Uri _origin;
  final Future<void> Function(Duration) _sleep;
  final _requests = <HttpClientRequest>{};
  final _streams = <StreamIterator<List<int>>>{};
  final _closedSignal = Completer<void>();
  bool _closed = false;

  Uri downloadUri(String blobId) {
    // OdmlService.downloadMediaInParallel removes exactly one leading slash
    // before invoking the original ModelDownloader URL builder.
    final object = blobId.startsWith('/') ? blobId.substring(1) : blobId;
    return _origin.replace(
      path: '/v1/medias/foresight/$object:download',
      queryParameters: {'alt': 'media', 'key': _apiKey},
    );
  }

  Future<Uint8List> download({
    required String blobId,
    required int size,
    void Function(int received, int total)? onProgress,
  }) async {
    if (_closed) throw StateError('Model downloader is closed.');
    if (blobId.isEmpty || size <= 0) return Uint8List(0);
    final bytes = Uint8List(size);
    final chunkSize = (size + parallelCount - 1) ~/ parallelCount;
    var received = 0;
    final stopwatch = Stopwatch()..start();
    var lastProgress = 0;
    final uri = downloadUri(blobId);
    try {
      await Future.wait([
        for (var index = 0; index < parallelCount; index++)
          if (index * chunkSize < size)
            _downloadChunk(
              uri,
              bytes,
              index * chunkSize,
              ((index + 1) * chunkSize - 1).clamp(0, size - 1),
              (count) {
                received += count;
                final now = stopwatch.elapsedMicroseconds;
                if (now - lastProgress >= 250000) {
                  lastProgress = now;
                  onProgress?.call(received, size);
                }
              },
            ),
      ]);
    } catch (error) {
      if (error is NonRetryableModelDownloadException) rethrow;
      if (_closed) throw StateError('Model downloader is closed.');
      // Retryability has already been decided inside each chunk. Do not expose
      // HttpException.uri or SocketException text through setup/UI failures.
      throw ModelTransportException(error.runtimeType.toString());
    }
    return bytes;
  }

  Future<void> _downloadChunk(
    Uri uri,
    Uint8List bytes,
    int start,
    int end,
    void Function(int) received,
  ) async {
    var cursor = start;
    for (var attempt = 1; ; attempt++) {
      HttpClientRequest? request;
      StreamIterator<List<int>>? stream;
      try {
        if (_closed) throw StateError('Model downloader is closed.');
        if (cursor > end) return;
        request = await _client.getUrl(uri);
        _requests.add(request);
        if (_closed) {
          request.abort();
          throw StateError('Model downloader is closed.');
        }
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$cursor-$end');
        final response = await request.close();
        final status = response.statusCode;
        if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
          await response.listen(null).cancel();
          if (const {429, 500, 502, 503, 504}.contains(status)) {
            throw HttpException('Retryable model response ($status).');
          }
          throw NonRetryableModelDownloadException(
            'Unexpected response ($status).',
            statusCode: status,
          );
        }
        if (status == HttpStatus.ok &&
            (start != 0 || end != bytes.length - 1)) {
          await response.listen(null).cancel();
          throw const NonRetryableModelDownloadException(
            'Server ignored a partial range.',
          );
        }
        stream = StreamIterator(response);
        _streams.add(stream);
        while (await stream.moveNext()) {
          if (_closed) throw StateError('Model downloader is closed.');
          final block = stream.current;
          // The original destination buffer performs this bounds check too.
          bytes.setRange(cursor, cursor + block.length, block);
          cursor += block.length;
          received(block.length);
        }
        if (_closed) throw StateError('Model downloader is closed.');
        // Original accepts EOF without a per-chunk length assertion. The caller
        // must authenticate the complete asset before installing it.
        return;
      } catch (error) {
        final retryable =
            error is HttpException ||
            error is SocketException ||
            error is TimeoutException;
        if (!retryable || attempt >= retryPolicy.maxAttempts || _closed)
          rethrow;
        await Future.any([
          _sleep(retryPolicy.delay(attempt)),
          _closedSignal.future,
        ]);
      } finally {
        if (request != null) _requests.remove(request);
        if (stream != null) {
          _streams.remove(stream);
          await stream.cancel();
        }
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _closedSignal.complete();
    for (final request in _requests) {
      request.abort();
    }
    for (final stream in _streams) {
      unawaited(stream.cancel());
    }
    if (_ownsClient) _client.close(force: true);
  }
}
