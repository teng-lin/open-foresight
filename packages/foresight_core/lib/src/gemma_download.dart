import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';

class GemmaModel {
  final String name, repository, revision, filename, digest;
  final int bytes, minimumMemoryGb;
  const GemmaModel(
    this.name,
    this.repository,
    this.revision,
    this.filename,
    this.digest,
    this.bytes,
    this.minimumMemoryGb,
  );
  Uri get url =>
      Uri.https('huggingface.co', '/$repository/resolve/$revision/$filename');
  String get directory =>
      '${filename.replaceAll('.litertlm', '')}-${digest.substring(0, 12)}';
}

// Pinned public artifact metadata, independently verified 2026-10-13. These
// are not assumed identical to Foresight's encrypted Mac service artifacts.
const gemmaModels = [
  GemmaModel(
    'Gemma 4 12B',
    'litert-community/gemma-4-12B-it-litert-lm',
    '7a0b1ce0ea821bcd01c5f72af84155e02191152f',
    'gemma-4-12B-it.litertlm',
    '58fd31b778ca2c21c80d634fb34fc5a89d11d563a38dfd3cbf1b40dbf252a8b6',
    6883278368,
    30,
  ),
  GemmaModel(
    'Gemma 4 E4B',
    'litert-community/gemma-4-E4B-it-litert-lm',
    '2eee7ac325f20eb8c9ac1d0e972f7c84663062da',
    'gemma-4-E4B-it.litertlm',
    '0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0',
    3659530240,
    15,
  ),
  GemmaModel(
    'Gemma 4 E2B',
    'litert-community/gemma-4-E2B-it-litert-lm',
    'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1',
    'gemma-4-E2B-it.litertlm',
    '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
    2588147712,
    6,
  ),
];

const embeddingGemmaModel = GemmaModel(
  'EmbeddingGemma 2',
  'litert-community/embeddinggemma-2-740m-litert-lm',
  '24d962e906c7d332c6428e71c9676855024569e2',
  'embeddinggemma-2-740m.litertlm',
  'e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c',
  484622336,
  0,
);

enum ModelDownloadPhase {
  checkingCache,
  verifyingCache,
  downloading,
  verifyingDownload,
}

class ModelDownloadCancelled implements Exception {
  const ModelDownloadCancelled();
  @override
  String toString() => 'Model download cancelled';
}

/// One owned download. Never mutates the application registry. Only a fully
/// verified file becomes visible at the final path; cancellation removes its
/// own temporary file and preserves previously completed assets.
class GemmaDownload {
  final HttpClient Function() createClient;
  final Duration timeout;
  final int parallelism, rangeThreshold;
  HttpClient? _client;
  bool _cancelled = false, _active = false;
  GemmaDownload({
    HttpClient Function()? createClient,
    this.timeout = const Duration(seconds: 30),
    this.parallelism = 4,
    this.rangeThreshold = 64 * 1024 * 1024,
  }) : createClient = createClient ?? (() => HttpClient());
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  void _check() {
    if (_cancelled) throw const ModelDownloadCancelled();
  }

  Future<File> download(
    GemmaModel model,
    Directory root, {
    void Function(int received, int total)? progress,
    void Function(ModelDownloadPhase)? phase,
    Uri? sourceForTesting,
  }) async {
    if (_active || _cancelled)
      throw StateError('Download is active or cancelled');
    _active = true;
    File? partial;
    IOSink? sink;
    try {
      if (parallelism < 1 || parallelism > 8 || rangeThreshold < 0)
        throw ArgumentError('Invalid download parallelism');
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(model.digest) ||
          model.bytes <= 0 ||
          model.filename.contains('/') ||
          model.filename.contains('\\') ||
          !(model.filename.endsWith('.litertlm') ||
              model.filename.endsWith('.bin')))
        throw ArgumentError('Invalid model metadata');
      phase?.call(ModelDownloadPhase.checkingCache);
      final directory = Directory('${root.path}/${model.directory}');
      await directory.create(recursive: true);
      final destination = File('${directory.path}/${model.filename}');
      final type = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound) {
        phase?.call(ModelDownloadPhase.verifyingCache);
        if (type != FileSystemEntityType.file ||
            await destination.length() != model.bytes ||
            (await sha256.bind(destination.openRead()).first).toString() !=
                model.digest)
          throw StateError(
            'Existing model file failed verification; it was preserved',
          );
        _check();
        progress?.call(model.bytes, model.bytes);
        return destination;
      }
      _check();
      final temporary = await directory.createTemp('.download-');
      partial = File('${temporary.path}/model.part');
      sink = partial.openWrite();
      phase?.call(ModelDownloadPhase.downloading);
      final client = _client = createClient();
      client.autoUncompress = false;
      client.connectionTimeout = timeout;
      final uri = sourceForTesting ?? model.url;
      var received = 0;
      void report(int count) {
        received += count;
        progress?.call(received, model.bytes);
      }

      final count = model.bytes >= rangeThreshold ? parallelism : 1;
      final block = (model.bytes + count - 1) ~/ count;
      final firstEnd = block - 1 < model.bytes ? block - 1 : model.bytes - 1;
      final first = await _response(
        client,
        uri,
        range: count > 1 ? 'bytes=0-$firstEnd' : null,
      );
      if (count > 1 && first.statusCode == 206) {
        final parts = <File>[];
        final jobs = <Future<void>>[];
        for (
          var index = 0;
          index < count && index * block < model.bytes;
          index++
        ) {
          final start = index * block;
          final end = start + block - 1 < model.bytes
              ? start + block - 1
              : model.bytes - 1;
          final file = File('${temporary.path}/range-$index.part');
          parts.add(file);
          jobs.add(() async {
            IOSink? output;
            try {
              final response = index == 0
                  ? first
                  : await _response(client, uri, range: 'bytes=$start-$end');
              if (response.statusCode != 206 ||
                  response.headers.value(HttpHeaders.contentRangeHeader) !=
                      'bytes $start-$end/${model.bytes}')
                throw StateError('Model server returned an invalid byte range');
              output = file.openWrite();
              await _body(response, output, end - start + 1, report);
              await output.close();
              output = null;
            } catch (_) {
              client.close(force: true);
              rethrow;
            } finally {
              try {
                await output?.close();
              } catch (_) {}
            }
          }());
        }
        await Future.wait(jobs);
        for (final file in parts) {
          _check();
          await sink.addStream(file.openRead());
          await file.delete();
        }
      } else {
        // Servers that ignore Range can still provide a verified whole file.
        if (first.statusCode != 200)
          throw StateError('Model download server returned an error');
        await _body(first, sink, model.bytes, report);
      }
      await sink.close();
      sink = null;
      _check();
      phase?.call(ModelDownloadPhase.verifyingDownload);
      if (received != model.bytes ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              model.digest)
        throw StateError('Model download failed size or hash verification');
      _check();
      // A hard link atomically publishes the verified inode and refuses to
      // overwrite any destination, including a concurrent downloader's file.
      final published = await Process.run(
        Platform.isMacOS ? '/bin/ln' : '/usr/bin/ln',
        ['--', partial.path, destination.path],
      );
      if (published.exitCode != 0)
        throw StateError(
          'Model could not be published; existing files were preserved',
        );
      await partial.delete();
      partial = null;
      await temporary.delete();
      return destination;
    } catch (failure) {
      if (_cancelled) throw const ModelDownloadCancelled();
      if (failure is HttpException ||
          failure is SocketException ||
          failure is HandshakeException ||
          failure is TimeoutException)
        throw StateError(
          'Model transfer failed. Check the connection and retry.',
        );
      rethrow;
    } finally {
      _client?.close(force: true);
      _client = null;
      try {
        await sink?.close();
      } catch (_) {}
      if (partial != null) {
        final directory = partial.parent;
        if (await partial.exists()) await partial.delete();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
      _active = false;
    }
  }

  Future<HttpClientResponse> _response(
    HttpClient client,
    Uri source, {
    String? range,
  }) async {
    var uri = source;
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (uri.scheme != 'https' || uri.userInfo.isNotEmpty)
        throw StateError('Model downloads require HTTPS');
      _check();
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (![301, 302, 303, 307, 308].contains(response.statusCode))
        return response;
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null || redirects == 5)
        throw StateError('Model download redirect failed');
      uri = uri.resolve(location);
      await response.listen((_) {}).cancel();
    }
    throw StateError('Model download redirect failed');
  }

  Future<void> _body(
    HttpClientResponse response,
    IOSink sink,
    int expected,
    void Function(int) progress,
  ) async {
    if (response.contentLength >= 0 && response.contentLength != expected)
      throw StateError('Model download size does not match');
    var received = 0, pending = 0;
    await for (final chunk in response.timeout(timeout)) {
      _check();
      received += chunk.length;
      if (received > expected) throw StateError('Model download is too large');
      sink.add(chunk);
      pending += chunk.length;
      if (pending >= 1024 * 1024) {
        await sink.flush();
        pending = 0;
      }
      progress(chunk.length);
    }
    if (received != expected) throw StateError('Model download was incomplete');
  }
}

int physicalMemoryGb() {
  if (Platform.isLinux) {
    final text = File('/proc/meminfo').readAsStringSync();
    final kb = int.tryParse(
      RegExp(r'MemTotal:\s+(\d+)').firstMatch(text)?.group(1) ?? '',
    );
    return kb == null ? 0 : (kb / (1024 * 1024)).round();
  }
  return 0;
}
