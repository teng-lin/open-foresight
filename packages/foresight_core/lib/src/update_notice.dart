import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum UpdateNoticeProblem {
  unavailable,
  timedOut,
  untrustedMetadata,
  invalidMetadata,
  wrongChannel,
  cancelled,
}

final class UpdateNoticeException implements Exception {
  const UpdateNoticeException(this.problem);
  final UpdateNoticeProblem problem;
}

final class UpdateNoticeResult {
  const UpdateNoticeResult.disabled()
    : enabled = false,
      version = null,
      releasePage = null;
  const UpdateNoticeResult.current()
    : enabled = true,
      version = null,
      releasePage = null;
  const UpdateNoticeResult.available(this.version, this.releasePage)
    : enabled = true;

  final bool enabled;
  final String? version;
  final Uri? releasePage;
  bool get hasUpdate => version != null;
}

typedef UpdateMetadataTransport =
    Future<List<int>> Function(Uri endpoint, Duration timeout);

/// A manual, opt-in notice. Constructing this client never opens a connection.
///
/// Production authenticates the fixed GitHub API endpoint using the platform
/// TLS trust store. Redirects and metadata for another repository or channel
/// are rejected. This checks release metadata, not installer signatures; it
/// neither downloads installers nor authorizes their execution.
final class UpdateNoticeClient {
  UpdateNoticeClient({
    UpdateMetadataTransport? transport,
    HttpClient Function()? createClient,
    this.timeout = const Duration(seconds: 5),
  }) : _transport = transport,
       _createClient = createClient ?? HttpClient.new {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
  }

  static final endpoint = Uri.https(
    'api.github.com',
    '/repos/teng-lin/open-foresight/releases/latest',
  );
  static const maximumMetadataBytes = 256 * 1024;
  final Duration timeout;
  final UpdateMetadataTransport? _transport;
  final HttpClient Function() _createClient;
  final Set<HttpClient> _active = {};
  bool _closed = false;
  int _generation = 0;

  Future<UpdateNoticeResult> check({
    required bool enabled,
    required String currentVersion,
    String channel = 'stable',
  }) async {
    if (!enabled) return const UpdateNoticeResult.disabled();
    if (_closed) {
      throw const UpdateNoticeException(UpdateNoticeProblem.cancelled);
    }
    if (channel != 'stable') {
      throw const UpdateNoticeException(UpdateNoticeProblem.wrongChannel);
    }
    final current = _Version.parse(currentVersion, releaseTag: false);
    final generation = _generation;
    try {
      final bytes = await (_transport?.call(endpoint, timeout) ?? _read())
          .timeout(timeout);
      if (_closed || generation != _generation) {
        throw const UpdateNoticeException(UpdateNoticeProblem.cancelled);
      }
      if (bytes.length > maximumMetadataBytes) {
        throw const UpdateNoticeException(UpdateNoticeProblem.invalidMetadata);
      }
      final metadata = jsonDecode(utf8.decode(bytes));
      if (metadata is! Map<String, dynamic>) {
        throw const UpdateNoticeException(UpdateNoticeProblem.invalidMetadata);
      }
      final id = metadata['id'];
      final tag = metadata['tag_name'];
      if (id is! int || id <= 0 || tag is! String) {
        throw const UpdateNoticeException(UpdateNoticeProblem.invalidMetadata);
      }
      final release = _Version.parse(tag, releaseTag: true);
      final page = Uri.https(
        'github.com',
        '/teng-lin/open-foresight/releases/tag/$tag',
      );
      final api = Uri.https(
        'api.github.com',
        '/repos/teng-lin/open-foresight/releases/$id',
      );
      if (metadata['html_url'] != page.toString() ||
          metadata['url'] != api.toString()) {
        throw const UpdateNoticeException(
          UpdateNoticeProblem.untrustedMetadata,
        );
      }
      if (metadata['draft'] != false || metadata['prerelease'] != false) {
        throw const UpdateNoticeException(UpdateNoticeProblem.wrongChannel);
      }
      if (release.compareTo(current) <= 0) {
        return const UpdateNoticeResult.current();
      }
      return UpdateNoticeResult.available(tag.substring(1), page);
    } catch (error) {
      if (_closed || generation != _generation) {
        throw const UpdateNoticeException(UpdateNoticeProblem.cancelled);
      }
      if (error is UpdateNoticeException) rethrow;
      if (error is TimeoutException) {
        throw const UpdateNoticeException(UpdateNoticeProblem.timedOut);
      }
      if (error is TlsException) {
        throw const UpdateNoticeException(
          UpdateNoticeProblem.untrustedMetadata,
        );
      }
      if (error is FormatException) {
        throw const UpdateNoticeException(UpdateNoticeProblem.invalidMetadata);
      }
      if (error is IOException) {
        throw const UpdateNoticeException(UpdateNoticeProblem.unavailable);
      }
      rethrow;
    }
  }

  Future<List<int>> _read() async {
    final client = _createClient()..connectionTimeout = timeout;
    _active.add(client);
    try {
      return await (() async {
        final request = await client.getUrl(endpoint);
        request.followRedirects = false;
        request.headers
          ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
          ..set(HttpHeaders.userAgentHeader, 'open-foresight-update-check')
          ..set('X-GitHub-Api-Version', '2022-11-28');
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw const UpdateNoticeException(UpdateNoticeProblem.unavailable);
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maximumMetadataBytes) {
            throw const UpdateNoticeException(
              UpdateNoticeProblem.invalidMetadata,
            );
          }
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      })().timeout(timeout);
    } finally {
      _active.remove(client);
      client.close(force: true);
    }
  }

  void cancelPending() {
    _generation++;
    for (final client in _active) {
      client.close(force: true);
    }
  }

  void close() {
    _closed = true;
    cancelPending();
  }
}

final class _Version implements Comparable<_Version> {
  const _Version(this.parts);
  final List<int> parts;

  static _Version parse(String value, {required bool releaseTag}) {
    final pattern = RegExp(
      '${releaseTag ? '^v' : '^'}'
      r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
      '${releaseTag ? r'$' : r'(?:\+[A-Za-z0-9.-]+)?$'}',
    );
    final match = pattern.firstMatch(value);
    final parts = match == null
        ? null
        : [
            for (var index = 1; index <= 3; index++)
              int.tryParse(match[index]!),
          ];
    if (parts == null || parts.any((part) => part == null)) {
      throw const UpdateNoticeException(UpdateNoticeProblem.invalidMetadata);
    }
    return _Version(parts.cast<int>());
  }

  @override
  int compareTo(_Version other) {
    for (var index = 0; index < 3; index++) {
      final comparison = parts[index].compareTo(other.parts[index]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }
}
