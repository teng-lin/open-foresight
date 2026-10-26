import 'public_model_budget.dart';
import 'gemma_download.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:path/path.dart' as path;

import 'generated/web_content.pbgrpc.dart';
import 'web_content.dart' show referenceWebContentHost;
import 'platform_services.dart' show runtimeConfiguration;
import 'runtime_execution_policy.dart' show requireInstalledRuntime;
import 'rpc_error.dart' show RpcError;

export 'generated/web_content.pb.dart'
    show ForesightSharedConfig, GetSharedConfigRequest, OnDeviceModelMetadata;

const referenceQueryDetectorModelType = 4;
const referenceClosestLowerFallback = 1;
const referenceModelDownloadBytesPerSlot = 838860800;

/// Original AssetManager divides by the double 800 MiB, ceils, then clamps.
int referenceModelDownloadParallelCount(int size) =>
    (size / referenceModelDownloadBytesPerSlot).ceil().clamp(1, 8);

class ModelDownloadPlan {
  const ModelDownloadPlan({required this.metadata, required this.blobName});
  final OnDeviceModelMetadata metadata;
  final String blobName;
}

/// Original downloadModelsByType overwrites earlier entries of the same type.
/// _downloadModel then passes basename(blobId) to the HTTP media helper.
/// This does not infer a version ordering or implement the server refresh policy.
ModelDownloadPlan? referenceModelDownloadPlan(
  Iterable<OnDeviceModelMetadata> models,
  int modelType,
) {
  OnDeviceModelMetadata? selected;
  for (final model in models) {
    if (model.modelType == modelType) selected = model;
  }
  return selected == null
      ? null
      : ModelDownloadPlan(
          metadata: selected,
          blobName: path.posix.basename(selected.blobId),
        );
}

/// Public metadata RPC recovered from the original OdmlService.
/// The credential comes from the same distribution configuration as web content.
class ModelConfigService {
  ModelConfigService({
    required String apiKey,
    ClientChannel? channel,
    Duration timeout = const Duration(seconds: 30),
  }) : _apiKey = apiKey,
       _timeout = timeout,
       _ownsChannel = channel == null,
       _channel =
           channel ??
           ClientChannel(
             referenceWebContentHost,
             port: 443,
             options: const ChannelOptions(
               credentials: ChannelCredentials.secure(),
             ),
           ) {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    _client = ForesightServiceClient(
      _channel,
      options: CallOptions(metadata: {'X-Goog-Api-Key': apiKey}),
    );
  }

  final String _apiKey;
  final Duration _timeout;
  final _workers = <_ModelTransportProcess>{};
  final bool _ownsChannel;
  final ClientChannel _channel;
  late final ForesightServiceClient _client;
  final _requests = <ResponseFuture<ForesightSharedConfig>>{};
  bool _closed = false;
  Future<void>? _closing;

  Future<ForesightSharedConfig> fetch({required String appVersion}) {
    if (_closed) throw StateError('Model configuration service is closed.');
    if (appVersion.isEmpty) throw ArgumentError.value(appVersion, 'appVersion');
    if (_ownsChannel) return _fetchInWorker(appVersion);
    final request = _client.getSharedConfig(
      GetSharedConfigRequest(
        appVersion: appVersion,
        platform: 'macos',
        fallbackMode: referenceClosestLowerFallback,
      ),
      options: CallOptions(timeout: _timeout),
    );
    _requests.add(request);
    return request
        .timeout(
          _timeout,
          onTimeout: () {
            unawaited(request.cancel());
            throw const ModelTransportException('metadata_timeout');
          },
        )
        .whenComplete(() => _requests.remove(request));
  }

  Future<ForesightSharedConfig> _fetchInWorker(String appVersion) async {
    final worker = _ModelTransportProcess();
    _workers.add(worker);
    try {
      final bytes = await worker.run(
        {
          'kind': 'metadata',
          'apiKey': _apiKey,
          'appVersion': appVersion,
          'timeout': _timeout.inMicroseconds,
        },
        _timeout,
        1024 * 1024,
      );
      return ForesightSharedConfig.fromBuffer(bytes);
    } finally {
      _workers.remove(worker);
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait([
      for (final worker in _workers.toList()) worker.cancel(),
    ]);
    await Future.wait([
      for (final request in _requests.toList()) request.cancel(),
    ]);
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

/// Every transport phase and each attempt is bounded independently of progress.
/// The total includes retry delays and all parallel ranges.
class ModelTransportDeadlines {
  const ModelTransportDeadlines({
    this.connect = const Duration(seconds: 30),
    this.headers = const Duration(seconds: 30),
    this.bodyIdle = const Duration(seconds: 30),
    this.attempt = const Duration(minutes: 5),
    this.total = const Duration(minutes: 15),
  });
  final Duration connect, headers, bodyIdle, attempt, total;

  void validate() {
    for (final duration in [connect, headers, bodyIdle, attempt, total]) {
      if (duration <= Duration.zero) {
        throw ArgumentError.value(duration, 'transport deadline');
      }
    }
  }
}

/// The parent owns transport process termination, including a stalled TLS
/// handshake which the pinned Dart socket cancellation cannot reliably close.
class ModelBlobDownloader {
  ModelBlobDownloader({
    required String apiKey,
    this.parallelCount,
    ModelDownloadRetryPolicy? retryPolicy,
    HttpClient? client,
    Uri? origin,
    Future<void> Function(Duration)? sleep,
    this.deadlines = const ModelTransportDeadlines(),
  }) : retryPolicy = retryPolicy ?? ModelDownloadRetryPolicy.reference(),
       _apiKey = apiKey,
       _origin = origin ?? Uri.https(referenceWebContentHost) {
    deadlines.validate();
    if (parallelCount != null && (parallelCount! <= 0 || parallelCount! > 8)) {
      throw ArgumentError.value(parallelCount, 'parallelCount');
    }
    if (this.retryPolicy.maxAttempts <= 0 ||
        this.retryPolicy.maxAttempts > 20) {
      throw ArgumentError.value(this.retryPolicy.maxAttempts, 'maxAttempts');
    }
    // Injection preserves offline fixture semantics. Production transport has
    // its own OS process and never borrows a caller's HttpClient or handles.
    if (client != null || sleep != null) {
      _local = _LocalModelBlobDownloader(
        apiKey: apiKey,
        parallelCount: parallelCount,
        retryPolicy: this.retryPolicy,
        client: client,
        origin: origin,
        sleep: sleep,
        deadlines: deadlines,
      );
    }
  }
  final String _apiKey;
  final Uri _origin;
  final int? parallelCount;
  final ModelDownloadRetryPolicy retryPolicy;
  final ModelTransportDeadlines deadlines;
  _LocalModelBlobDownloader? _local;
  final _workers = <_ModelTransportProcess>{};
  bool _closed = false;
  final _closedSignal = Completer<void>();
  Uri downloadUri(String blobId) => _origin.replace(
    path:
        '/v1/medias/foresight/${blobId.startsWith('/') ? blobId.substring(1) : blobId}:download',
    queryParameters: {'alt': 'media', 'key': _apiKey},
  );

  Future<Uint8List> download({
    required String blobId,
    required int size,
    void Function(int, int)? onProgress,
  }) async {
    if (_closed) throw StateError('Model downloader is closed.');
    if (blobId.isEmpty || size <= 0) return Uint8List(0);
    if (size > _maxTransportBytes) throw ArgumentError.value(size, 'size');
    if (_local case final local?) {
      return local.download(blobId: blobId, size: size, onProgress: onProgress);
    }
    final total = Stopwatch()..start();
    var attemptsUsed = 0;
    while (true) {
      if (_closed) throw StateError('Model downloader is closed.');
      final remaining = deadlines.total - total.elapsed;
      if (remaining <= Duration.zero) {
        throw const ModelTransportException('total_timeout');
      }
      final worker = _ModelTransportProcess();
      _workers.add(worker);
      try {
        return await worker.run(
          {
            'kind': 'download',
            'apiKey': _apiKey,
            'origin': _origin.toString(),
            'blobId': blobId,
            'size': size,
            'parallelCount': parallelCount,
            'attempts': retryPolicy.maxAttempts - attemptsUsed,
            'delays': [
              for (var i = attemptsUsed + 1; i < retryPolicy.maxAttempts; i++)
                retryPolicy.delay(i).inMicroseconds,
            ],
            'connect': deadlines.connect.inMicroseconds,
            'headers': deadlines.headers.inMicroseconds,
            'bodyIdle': deadlines.bodyIdle.inMicroseconds,
            'attempt': deadlines.attempt.inMicroseconds,
            'total': remaining.inMicroseconds,
          },
          remaining,
          size,
          onProgress: onProgress,
        );
      } on _ModelConnectDeadline catch (error) {
        attemptsUsed += error.attempts;
        if (attemptsUsed >= retryPolicy.maxAttempts) {
          throw const ModelTransportException('connect_timeout');
        }
        // run() has already terminated and reaped the old process. No TLS
        // socket from that attempt survives into this retry.
        final delay = retryPolicy.delay(attemptsUsed);
        if (delay < Duration.zero) {
          throw ArgumentError.value(delay, 'retry delay');
        }
        if (delay >= deadlines.total - total.elapsed) {
          throw const ModelTransportException('total_timeout');
        }
        final pause = Completer<void>();
        final timer = Timer(delay, pause.complete);
        try {
          await Future.any([pause.future, _closedSignal.future]);
        } finally {
          timer.cancel();
        }
      } catch (_) {
        if (_closed) throw StateError('Model downloader is closed.');
        rethrow;
      } finally {
        _workers.remove(worker);
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _closedSignal.complete();
    _local?.close();
    for (final worker in _workers.toList()) {
      // The owned download Future joins and reports teardown failure. This
      // eager signal must not create an unhandled secondary Future.
      unawaited(worker.cancel().catchError((Object _) {}));
    }
  }
}

/// Inclusive parallel ranges and resume cursors follow original ChunkDownloader.
/// This returns transport bytes; authentication and atomic registration happen
/// separately, before replacing an installed model.
/// Public assets retain their resumable file engine inside the same reaped
/// transport worker used for question-model acquisition. Only a short final path
/// returns to the parent; multi-gigabyte model contents never enter its buffer.
class PublicModelFileDownloader implements ModelDownloader {
  PublicModelFileDownloader({
    ModelTransportDeadlines? deadlines,
    ModelDownloadRetryPolicy? retryPolicy,
    Future<Process> Function(List<String> command)? startWorkerForTesting,
  }) : _testDeadlines = deadlines,
       _startWorkerForTesting = startWorkerForTesting,
       retryPolicy = retryPolicy ?? ModelDownloadRetryPolicy.reference() {
    deadlines?.validate();
    if (this.retryPolicy.maxAttempts <= 0 ||
        this.retryPolicy.maxAttempts > 20) {
      throw ArgumentError.value(this.retryPolicy.maxAttempts, 'maxAttempts');
    }
  }
  final ModelTransportDeadlines? _testDeadlines;
  // Controlled process/acknowledgement fixtures use the same ownership path.
  // Production keeps the private worker's environment and default launcher.
  final Future<Process> Function(List<String> command)? _startWorkerForTesting;
  final ModelDownloadRetryPolicy retryPolicy;
  ModelTransportDeadlines deadlinesFor(GemmaModel model) {
    if (_testDeadlines case final deadlines?) return deadlines;
    final attempt = publicModelAttemptBudget(model);
    return ModelTransportDeadlines(
      attempt: attempt,
      total: attempt * retryPolicy.maxAttempts + const Duration(minutes: 1),
    );
  }

  _ModelTransportProcess? _worker;
  final _cancelledSignal = Completer<void>();
  bool _cancelled = false, _active = false;

  @override
  void cancel() {
    _cancelled = true;
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
    _worker?.cancel().ignore();
  }

  void _check() {
    if (_cancelled) throw const ModelDownloadCancelled();
  }

  @override
  Future<File> download(
    GemmaModel model,
    Directory root, {
    void Function(int, int)? progress,
    void Function(ModelDownloadPhase)? phase,
    Uri? sourceForTesting,
    File? existingFile,
  }) async {
    if (_active || _cancelled) {
      throw StateError('Download is active or cancelled');
    }
    _active = true;
    final deadlines = deadlinesFor(model);
    final elapsed = Stopwatch()..start();
    try {
      for (var attempt = 1; ; attempt++) {
        _check();
        final remaining = deadlines.total - elapsed.elapsed;
        if (remaining <= Duration.zero) {
          throw const ModelTransportException('total_timeout');
        }
        final worker = _worker = _ModelTransportProcess(
          startWorker: _startWorkerForTesting,
        );
        try {
          final path = await worker.run(
            {
              'kind': 'public_file',
              'apiKey': '',
              'name': model.name,
              'repository': model.repository,
              'revision': model.revision,
              'filename': model.filename,
              'digest': model.digest,
              'bytes': model.bytes,
              'memory': model.minimumMemoryGb,
              'root': root.path,
              'existing': existingFile?.path,
              'source': (sourceForTesting ?? compiledFixtureModelSource(model))
                  ?.toString(),
              'connect': deadlines.connect.inMicroseconds,
              'headers': deadlines.headers.inMicroseconds,
              'bodyIdle': deadlines.bodyIdle.inMicroseconds,
            },
            remaining < deadlines.attempt ? remaining : deadlines.attempt,
            16384,
            progressTotal: model.bytes,
            onProgress: progress,
            onPhase: phase,
          );
          _check();
          return File(utf8.decode(path));
        } catch (error) {
          _check();
          final retryable =
              error is ModelTransportException &&
                  error.failureType == 'total_timeout' ||
              error is ModelAssetFailure &&
                  error.code == ModelAssetFailureCode.interrupted;
          if (!retryable || attempt >= retryPolicy.maxAttempts) {
            rethrow;
          }
          final left = deadlines.total - elapsed.elapsed;
          final delay = retryPolicy.delay(attempt);
          if (left <= Duration.zero || delay >= left) {
            throw const ModelTransportException('total_timeout');
          }
          await Future.any<void>([
            Future<void>.delayed(delay),
            _cancelledSignal.future,
          ]);
        } finally {
          try {
            await worker.cancel();
          } catch (_) {
            throw const ModelTransportException('worker_exit_unknown');
          } finally {
            if (identical(_worker, worker)) _worker = null;
          }
        }
      }
    } finally {
      _active = false;
    }
  }
}

class _LocalModelBlobDownloader {
  _LocalModelBlobDownloader({
    required String apiKey,
    this.parallelCount,
    ModelDownloadRetryPolicy? retryPolicy,
    HttpClient? client,
    Uri? origin,
    Future<void> Function(Duration)? sleep,
    this.deadlines = const ModelTransportDeadlines(),
    this.earlyFailure = false,
  }) : retryPolicy = retryPolicy ?? ModelDownloadRetryPolicy.reference(),
       _apiKey = apiKey,
       _client = client ?? HttpClient(),
       _ownsClient = client == null,
       _origin = origin ?? Uri.https(referenceWebContentHost),
       _sleep = sleep ?? Future<void>.delayed {
    deadlines.validate();
    // The operation timer owns the earlier deadline. The SDK's own timeout
    // cannot cancel an established TCP socket during a stalled TLS handshake.
    _client.connectionTimeout = deadlines.connect * 2;
    if (parallelCount != null && (parallelCount! <= 0 || parallelCount! > 8)) {
      throw ArgumentError.value(parallelCount, 'parallelCount');
    }
    if (this.retryPolicy.maxAttempts <= 0 ||
        this.retryPolicy.maxAttempts > 20) {
      throw ArgumentError.value(this.retryPolicy.maxAttempts, 'maxAttempts');
    }
  }

  final ModelTransportDeadlines deadlines;
  final bool earlyFailure;
  final String _apiKey;
  final int? parallelCount;
  final ModelDownloadRetryPolicy retryPolicy;
  final HttpClient _client;
  final bool _ownsClient;
  final Uri _origin;
  final Future<void> Function(Duration) _sleep;
  final _requests = <HttpClientRequest>{};
  final _streams = <StreamIterator<List<int>>>{};
  final _closedSignal = Completer<void>();
  final _closeEvents = StreamController<void>.broadcast(sync: true);
  bool _closed = false;
  var _attemptsUsed = 0;

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
    final slots = parallelCount ?? referenceModelDownloadParallelCount(size);
    final chunkSize = (size + slots - 1) ~/ slots;
    var received = 0;
    final stopwatch = Stopwatch()..start();
    var lastProgress = 0;
    final uri = downloadUri(blobId);
    try {
      await Future.wait([
        for (var index = 0; index < slots; index++)
          if (index * chunkSize < size)
            _downloadChunk(
              uri,
              bytes,
              index * chunkSize,
              ((index + 1) * chunkSize - 1).clamp(0, size - 1),
              stopwatch,
              (count) {
                received += count;
                final now = stopwatch.elapsedMicroseconds;
                if (now - lastProgress >= 250000) {
                  lastProgress = now;
                  onProgress?.call(received, size);
                }
              },
            ),
      ], eagerError: earlyFailure);
    } catch (error) {
      if (error is NonRetryableModelDownloadException ||
          error is _ModelConnectDeadline) {
        rethrow;
      }
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
    Stopwatch total,
    void Function(int) received,
  ) async {
    var cursor = start;
    for (var attempt = 1; ; attempt++) {
      _attemptsUsed = max(_attemptsUsed, attempt);
      HttpClientRequest? request;
      StreamIterator<List<int>>? stream;
      final attemptClock = Stopwatch()..start();
      Duration remaining(Duration phase) {
        final totalLeft = deadlines.total - total.elapsed;
        final attemptLeft = deadlines.attempt - attemptClock.elapsed;
        final bound = phase < totalLeft ? phase : totalLeft;
        final result = bound < attemptLeft ? bound : attemptLeft;
        if (result <= Duration.zero) {
          throw TimeoutException('Model transport deadline');
        }
        return result;
      }

      Future<T> bounded<T>(Future<T> future, Duration phase) async {
        final cancelled = Completer<T>();
        final subscription = _closeEvents.stream.listen((_) {
          if (!cancelled.isCompleted) {
            cancelled.completeError(StateError('Model downloader is closed.'));
          }
        });
        try {
          if (_closed) throw StateError('Model downloader is closed.');
          return await Future.any<T>([future, cancelled.future]).timeout(
            remaining(phase),
            onTimeout: () {
              request?.abort();
              if (stream != null) unawaited(stream.cancel());
              throw TimeoutException('Model transport deadline');
            },
          );
        } finally {
          await subscription.cancel();
        }
      }

      try {
        if (_closed) throw StateError('Model downloader is closed.');
        if (cursor > end) return;
        // A timed-out/cancelled connect can complete later. Retire that
        // request too; connectionTimeout bounds the underlying socket attempt.
        var connecting = true;
        final connection = _client.getUrl(uri).then((value) {
          if (!connecting || _closed) value.abort();
          return value;
        });
        try {
          request = await bounded(connection, deadlines.connect);
        } on TimeoutException {
          // Force an OS-process resource boundary before retrying TLS. Closing
          // HttpClient alone leaves the pinned SDK handshake socket alive.
          throw _ModelConnectDeadline(_attemptsUsed);
        } finally {
          connecting = false;
        }
        final activeRequest = request!;
        _requests.add(activeRequest);
        if (_closed) {
          activeRequest.abort();
          throw StateError('Model downloader is closed.');
        }
        activeRequest.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$cursor-$end',
        );
        final response = await bounded(
          activeRequest.close(),
          deadlines.headers,
        );
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
        while (await bounded(stream.moveNext(), deadlines.bodyIdle)) {
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
        request?.abort();
        if (stream != null) await stream.cancel();
        if (!retryable ||
            attempt >= retryPolicy.maxAttempts ||
            _closed ||
            total.elapsed >= deadlines.total) {
          rethrow;
        }
        final delay = retryPolicy.delay(attempt);
        if (delay < Duration.zero) {
          throw ArgumentError.value(delay, 'retry delay');
        }
        await Future.any([
          _sleep(delay),
          _closedSignal.future,
        ]).timeout(deadlines.total - total.elapsed);
      } finally {
        request?.abort();
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
    _closeEvents.add(null);
    unawaited(_closeEvents.close());
    for (final request in _requests) {
      request.abort();
    }
    for (final stream in _streams) {
      unawaited(stream.cancel());
    }
    if (_ownsClient) _client.close(force: true);
  }
}

class _ModelConnectDeadline implements Exception {
  const _ModelConnectDeadline(this.attempts);
  final int attempts;
}

const _maxTransportBytes = 512 * 1024 * 1024;
const _maxTransportConfiguration = 16 * 1024;

class _ModelTransportProcess {
  _ModelTransportProcess({this.startWorker});
  final Future<Process> Function(List<String> command)? startWorker;
  Process? _process;
  Future<Process>? _launching;
  bool _cancelled = false;
  final _cancelledSignal = Completer<void>();
  Future<void>? _cancelling;
  StreamIterator<List<int>>? _output;
  StreamIterator<List<int>>? _errors;

  Future<T> _untilCancelled<T>(Future<T> work) => Future.any<T>([
    work,
    _cancelledSignal.future.then<T>(
      (_) => throw const ModelTransportException('cancelled'),
    ),
  ]);

  Future<Uint8List> run(
    Map<String, Object?> config,
    Duration timeout,
    int maximum, {
    void Function(int, int)? onProgress,
    void Function(ModelDownloadPhase)? onPhase,
    int? progressTotal,
  }) async {
    final encoded = utf8.encode(jsonEncode(config));
    if (encoded.length > _maxTransportConfiguration) {
      throw const ModelTransportException('configuration_too_large');
    }
    final work = _run(
      encoded,
      maximum,
      onProgress,
      onPhase,
      progressTotal ?? maximum,
    );
    try {
      return await _untilCancelled(work).timeout(
        timeout,
        onTimeout: () => throw const ModelTransportException('total_timeout'),
      );
    } finally {
      // Failed cleanup is explicitly unconfirmed: surface restart authority
      // rather than waiting indefinitely for a failed acknowledgement again.
      await cancel();
      // Confirmed cleanup closes our stream owners and wakes the parser. Join
      // its actual settlement instead of leaving an EOF waiter behind.
      try {
        await work;
      } catch (_) {
        // The result/error above remains primary.
      }
    }
  }

  Future<Uint8List> _run(
    List<int> config,
    int maximum,
    void Function(int, int)? onProgress,
    void Function(ModelDownloadPhase)? onPhase,
    int progressTotal,
  ) async {
    final service = runtimeConfiguration['FORESIGHT_SERVICE'];
    final List<String> command;
    if (service != null &&
        service.startsWith('/') &&
        File(service).existsSync()) {
      try {
        command = [
          requireInstalledRuntime(service),
          '--model-transport-worker',
        ];
      } on RpcError {
        throw const ModelTransportException('worker_unavailable');
      }
    } else {
      // Source development only: use this Dart SDK and this package's source.
      // A compiled application must have its validated bundled service path.
      final source = await _untilCancelled(
        Isolate.resolvePackageUri(
          Uri.parse('package:foresight_core/src/model_transport_worker.dart'),
        ),
      );
      if (!Platform.resolvedExecutable.endsWith('/dart') ||
          source == null ||
          source.scheme != 'file' ||
          !File.fromUri(source).existsSync()) {
        throw const ModelTransportException('worker_unavailable');
      }
      command = [Platform.resolvedExecutable, source.toFilePath()];
    }
    if (_cancelled) throw const ModelTransportException('cancelled');
    final launch = _launching =
        startWorker?.call(command) ??
        Process.start(
          command.first,
          command.skip(1).toList(),
          includeParentEnvironment: false,
          environment: {
            if (Platform.environment['SYSTEMROOT'] case final root?)
              'SYSTEMROOT': root,
          },
        );
    final Process process;
    try {
      process = await launch;
    } on ProcessException {
      throw const ModelTransportException('worker_start');
    }
    _process = process;
    // No diagnostic bytes from the child are trusted or retained. Draining is
    // independent of stdout and cannot grow an in-memory stderr tail.
    final output = _output = StreamIterator(process.stdout);
    // StreamIterator subscribes lazily. Own the read end before cancellation
    // during launch/stdin close can retire it; cancelling an untouched iterator
    // would otherwise leave the process pipe open until VM finalization.
    var more = output.moveNext();
    more.ignore();
    final errors = _errors = StreamIterator(process.stderr);
    Future<void> discardErrors() async {
      while (await errors.moveNext()) {}
    }

    final errorsDone = discardErrors();
    errorsDone.ignore();
    if (_cancelled) {
      await cancel();
      throw const ModelTransportException('cancelled');
    }
    process.stdin.add(config);
    await _untilCancelled(process.stdin.close());
    final header = BytesBuilder(copy: false);
    Uint8List? result;
    var offset = 0;
    while (await more) {
      if (_cancelled) throw const ModelTransportException('cancelled');
      final chunk = output.current;
      var begin = 0;
      if (result == null) {
        while (begin < chunk.length && result == null) {
          final end = chunk.indexOf(10, begin);
          final stop = end < 0 ? chunk.length : end;
          if (header.length + stop - begin > 1024) {
            throw const ModelTransportException('invalid_worker_frame');
          }
          header.add(chunk.sublist(begin, stop));
          begin = end < 0 ? chunk.length : end + 1;
          if (end < 0) continue;
          final Object? decoded;
          try {
            decoded = jsonDecode(utf8.decode(header.takeBytes()));
          } on FormatException {
            throw const ModelTransportException('invalid_worker_frame');
          }
          if (decoded is! Map) {
            throw const ModelTransportException('invalid_worker_frame');
          }
          final value = decoded;
          if (value['progress'] is int &&
              value['total'] is int &&
              value['total'] == progressTotal &&
              value['progress'] >= 0 &&
              value['progress'] <= progressTotal) {
            onProgress?.call(value['progress'] as int, progressTotal);
            continue;
          }
          if (value['phase'] case final String phase) {
            final decodedPhase = ModelDownloadPhase.values
                .where((value) => value.name == phase)
                .firstOrNull;
            if (decodedPhase == null) {
              throw const ModelTransportException('invalid_worker_frame');
            }
            onPhase?.call(decodedPhase);
            continue;
          }
          if (value['ok'] == false) {
            if (value['kind'] == 'public_failure') {
              final code = ModelAssetFailureCode.values
                  .where((code) => code.name == value['code'])
                  .firstOrNull;
              final requiredBytes = value['required_bytes'];
              if (code == null ||
                  requiredBytes != null &&
                      (code != ModelAssetFailureCode.diskSpace ||
                          requiredBytes is! int ||
                          requiredBytes <= 0 ||
                          requiredBytes > 1024 * 1024 * 1024 * 1024)) {
                throw const ModelTransportException('invalid_worker_frame');
              }
              throw ModelAssetFailure(
                code,
                requiredBytes: requiredBytes as int?,
              );
            }
            if (value['kind'] == 'public_interrupted') {
              throw const ModelTransportException('public_interrupted');
            }
            if (value['kind'] == 'public_invalid') {
              throw const ModelTransportException('public_invalid');
            }
            final attempts = value['attempts'];
            if (value['kind'] == 'connect_timeout' &&
                attempts is int &&
                attempts > 0 &&
                attempts <= 20) {
              throw _ModelConnectDeadline(attempts);
            }
            if (value['kind'] == 'non_retryable') {
              final status = value['status'];
              if (status == null ||
                  status is int && status >= 100 && status <= 599) {
                throw NonRetryableModelDownloadException(
                  'Unexpected response.',
                  statusCode: status as int?,
                );
              }
            }
            throw const ModelTransportException('worker_transport');
          }
          final size = value['size'];
          if (value['ok'] != true ||
              size is! int ||
              size < 0 ||
              size > maximum ||
              size > _maxTransportBytes) {
            throw const ModelTransportException('invalid_worker_frame');
          }
          result = Uint8List(size);
        }
      }
      if (result != null && begin < chunk.length) {
        final count = chunk.length - begin;
        if (offset + count > result.length) {
          throw const ModelTransportException('worker_overflow');
        }
        result.setRange(offset, offset + count, chunk, begin);
        offset += count;
      }
      more = output.moveNext();
    }
    if (_cancelled) throw const ModelTransportException('cancelled');
    await errorsDone;
    if (_cancelled) throw const ModelTransportException('cancelled');
    final code = await _untilCancelled(process.exitCode);
    if (code != 0 || result == null || offset != result.length) {
      throw const ModelTransportException('worker_incomplete');
    }
    return result;
  }

  Future<void> cancel() {
    _cancelled = true;
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
    return _cancelling ??= () async {
      final launch = _launching;
      if (launch == null) return;
      final Process process;
      try {
        process = _process ?? await launch;
      } on ProcessException {
        return;
      } // No child exists to retire.
      try {
        await Future.wait([_stop(process), _closePipes(process)]);
      } catch (_) {
        throw const ModelTransportException('worker_exit_unknown');
      }
    }();
  }

  Future<void> _closePipes(Process process) async {
    // StreamIterator cancellation wakes pending moveNext calls, including the
    // diagnostic drainer; neither owner waits for an inherited pipe's EOF.
    await Future.wait([
      // Failed config delivery (for example EPIPE) does not make independently
      // confirmed child exit or reader retirement unknown. Still bound closure.
      process.stdin.close().then<void>((_) {}, onError: (Object _) {}),
      if (_output case final output?) output.cancel(),
      if (_errors case final errors?) errors.cancel(),
    ]).timeout(const Duration(seconds: 2));
  }

  Future<void> _stop(Process process) async {
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(milliseconds: 250));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 2));
    }
  }
}

/// Private service subprocess mode. It resolves no profile, opens no database,
/// loads no native application library, and has no service/logging authority.
Future<void> runModelTransportWorker() async {
  try {
    final input = BytesBuilder(copy: false);
    await for (final chunk in stdin) {
      if (input.length + chunk.length > _maxTransportConfiguration) {
        throw const FormatException('configuration');
      }
      input.add(chunk);
    }
    final config = jsonDecode(utf8.decode(input.takeBytes())) as Map;
    final apiKey = config['apiKey'] as String;
    if (apiKey.length > 8192) throw const FormatException('configuration');
    late Uint8List result;
    if (config['kind'] == 'metadata') {
      final channel = ClientChannel(
        referenceWebContentHost,
        port: 443,
        options: const ChannelOptions(credentials: ChannelCredentials.secure()),
      );
      final service = ModelConfigService(
        apiKey: apiKey,
        channel: channel,
        timeout: Duration(microseconds: config['timeout'] as int),
      );
      try {
        result = (await service.fetch(
          appVersion: config['appVersion'] as String,
        )).writeToBuffer();
      } finally {
        await service.close();
        await channel.terminate();
      }
    } else if (config['kind'] == 'public_file') {
      final downloader = GemmaDownload(
        timeout: Duration(microseconds: config['bodyIdle'] as int),
        connectTimeout: Duration(microseconds: config['connect'] as int),
        headerTimeout: Duration(microseconds: config['headers'] as int),
        bodyIdleTimeout: Duration(microseconds: config['bodyIdle'] as int),
      );
      final model = GemmaModel(
        config['name'] as String,
        config['repository'] as String,
        config['revision'] as String,
        config['filename'] as String,
        config['digest'] as String,
        config['bytes'] as int,
        config['memory'] as int,
      );
      try {
        final file = await downloader.download(
          model,
          Directory(config['root'] as String),
          existingFile: config['existing'] == null
              ? null
              : File(config['existing'] as String),
          sourceForTesting: config['source'] == null
              ? null
              : Uri.parse(config['source'] as String),
          progress: (received, total) => stdout.writeln(
            jsonEncode({'progress': received, 'total': total}),
          ),
          phase: (phase) => stdout.writeln(jsonEncode({'phase': phase.name})),
        );
        result = Uint8List.fromList(utf8.encode(file.path));
      } catch (error) {
        final failure = error is ModelAssetFailure
            ? error
            : ModelAssetFailure(ModelAssetFailureCode.invalid);
        stdout.writeln(
          jsonEncode({
            'ok': false,
            'kind': 'public_failure',
            'code': failure.code.name,
            if (failure.requiredBytes != null)
              'required_bytes': failure.requiredBytes,
          }),
        );
        await stdout.flush();
        return;
      } finally {
        downloader.cancel();
      }
    } else if (config['kind'] == 'download') {
      final delays = (config['delays'] as List).cast<int>();
      final size = config['size'] as int;
      if (size <= 0 ||
          size > _maxTransportBytes ||
          delays.length > 19 ||
          delays.any((d) => d < 0)) {
        throw const FormatException('configuration');
      }
      final downloader = _LocalModelBlobDownloader(
        earlyFailure: true,
        apiKey: apiKey,
        parallelCount: config['parallelCount'] as int?,
        origin: Uri.parse(config['origin'] as String),
        retryPolicy: ModelDownloadRetryPolicy(
          maxAttempts: config['attempts'] as int,
          delay: (attempt) => Duration(microseconds: delays[attempt - 1]),
        ),
        deadlines: ModelTransportDeadlines(
          connect: Duration(microseconds: config['connect'] as int),
          headers: Duration(microseconds: config['headers'] as int),
          bodyIdle: Duration(microseconds: config['bodyIdle'] as int),
          attempt: Duration(microseconds: config['attempt'] as int),
          total: Duration(microseconds: config['total'] as int),
        ),
      );
      try {
        result = await downloader.download(
          blobId: config['blobId'] as String,
          size: size,
          onProgress: (received, total) => stdout.writeln(
            jsonEncode({'progress': received, 'total': total}),
          ),
        );
      } finally {
        downloader.close();
      }
    } else {
      throw const FormatException('configuration');
    }
    stdout.writeln(jsonEncode({'ok': true, 'size': result.length}));
    stdout.add(result);
    await stdout.flush();
  } on _ModelConnectDeadline catch (error) {
    stdout.writeln(
      jsonEncode({
        'ok': false,
        'kind': 'connect_timeout',
        'attempts': error.attempts,
      }),
    );
    await stdout.flush();
  } on NonRetryableModelDownloadException catch (error) {
    stdout.writeln(
      jsonEncode({
        'ok': false,
        'kind': 'non_retryable',
        'status': error.statusCode,
      }),
    );
    await stdout.flush();
  } catch (_) {
    stdout.writeln('{"ok":false,"kind":"transport"}');
    await stdout.flush();
  }
  // Pending TLS handshakes in the pinned SDK may survive HttpClient.close and
  // isolate termination. OS process exit is the transport resource boundary.
  exit(0);
}
